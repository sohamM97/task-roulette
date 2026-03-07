import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:task_roulette/models/task.dart';
import 'package:task_roulette/widgets/task_card.dart';

void main() {
  Widget buildTestWidget({
    required Task task,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 200,
          height: 200,
          child: TaskCard(
            task: task,
            onTap: () {},
            onDelete: () {},
          ),
        ),
      ),
    );
  }

  group('TaskCard in-progress indicator', () {
    testWidgets('no indicator when task is not started and no started descendants', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        task: Task(id: 1, name: 'Normal task', createdAt: 1000),
      ));

      expect(find.byIcon(Icons.play_circle_filled), findsNothing);
    });

    testWidgets('shows play icon when task itself is started', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        task: Task(id: 1, name: 'WIP', createdAt: 1000, startedAt: 2000),
      ));

      expect(find.byIcon(Icons.play_circle_filled), findsOneWidget);
    });

    testWidgets('no indicator for completed started task', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        task: Task(id: 1, name: 'Done', createdAt: 1000, startedAt: 2000, completedAt: 3000),
      ));

      // isStarted is false when completed, so no indicator
      expect(find.byIcon(Icons.play_circle_filled), findsNothing);
    });

  });

  group('TaskCard long-press menu', () {
    testWidgets('shows Stop working option for started task', (tester) async {
      bool stopWorkingCalled = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 200,
            height: 200,
            child: TaskCard(
              task: Task(id: 1, name: 'WIP', createdAt: 1000, startedAt: 2000),
              onTap: () {},
              onDelete: () {},
              onStopWorking: () { stopWorkingCalled = true; },
            ),
          ),
        ),
      ));

      await tester.longPress(find.byType(TaskCard));
      await tester.pumpAndSettle();

      expect(find.text('Stop working'), findsOneWidget);

      await tester.tap(find.text('Stop working'));
      await tester.pumpAndSettle();

      expect(stopWorkingCalled, isTrue);
    });

    testWidgets('does not show Stop working when onStopWorking is null', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 200,
            height: 200,
            child: TaskCard(
              task: Task(id: 1, name: 'Not started', createdAt: 1000),
              onTap: () {},
              onDelete: () {},
              onStopWorking: null,
            ),
          ),
        ),
      ));

      await tester.longPress(find.byType(TaskCard));
      await tester.pumpAndSettle();

      expect(find.text('Stop working'), findsNothing);
    });
  });

  group('TaskCard parent tags', () {
    testWidgets('shows "Also under:" and parent names when parentNames provided', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 200,
            height: 200,
            child: TaskCard(
              task: Task(id: 1, name: 'Multi-parent task', createdAt: 1000),
              onTap: () {},
              onDelete: () {},
              parentNames: const ['Work', 'Urgent'],
            ),
          ),
        ),
      ));

      expect(find.text('Also under:'), findsOneWidget);
      expect(find.text('Work'), findsOneWidget);
      expect(find.text('Urgent'), findsOneWidget);
    });

    testWidgets('hides parent tags when parentNames is empty', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        task: Task(id: 1, name: 'Single parent task', createdAt: 1000),
      ));

      expect(find.text('Also under:'), findsNothing);
    });

    testWidgets('shows single parent name with "Also under:" prefix', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 200,
            height: 200,
            child: TaskCard(
              task: Task(id: 1, name: 'Task', createdAt: 1000),
              onTap: () {},
              onDelete: () {},
              parentNames: const ['Shopping'],
            ),
          ),
        ),
      ));

      expect(find.text('Also under:'), findsOneWidget);
      expect(find.text('Shopping'), findsOneWidget);
    });
  });

  group('TaskCard URL display', () {
    testWidgets('shows URL text on card when task has URL', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 200,
            child: TaskCard(
              task: Task(id: 1, name: 'Task', createdAt: 1000, url: 'https://example.com/page'),
              onTap: () {},
              onDelete: () {},
            ),
          ),
        ),
      ));

      expect(find.byIcon(Icons.link), findsOneWidget);
      expect(find.textContaining('example.com'), findsOneWidget);
    });

    testWidgets('no link icon when task has no URL', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        task: Task(id: 1, name: 'Task', createdAt: 1000),
      ));

      expect(find.byIcon(Icons.link), findsNothing);
    });
  });

  group('TaskCard blocked state', () {
    testWidgets('shows "After:" text when blocked with name', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 300,
            height: 200,
            child: TaskCard(
              task: Task(id: 1, name: 'Blocked task', createdAt: 1000),
              onTap: () {},
              onDelete: () {},
              isBlocked: true,
              blockedByName: 'Prerequisite',
            ),
          ),
        ),
      ));

      expect(find.text('After: Prerequisite'), findsOneWidget);
      expect(find.byIcon(Icons.hourglass_top), findsOneWidget);
    });

    testWidgets('no blocked text when not blocked', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        task: Task(id: 1, name: 'Free task', createdAt: 1000),
      ));

      expect(find.textContaining('After:'), findsNothing);
    });
  });

  group('TaskCard worked-on-today opacity', () {
    testWidgets('shows check_circle icon when worked on today', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        task: Task(
          id: 1,
          name: 'Done today',
          createdAt: 1000,
          lastWorkedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      ));

      expect(find.byIcon(Icons.check_circle), findsOneWidget);
    });

    testWidgets('no check_circle when not worked on today', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        task: Task(id: 1, name: 'Not done', createdAt: 1000),
      ));

      expect(find.byIcon(Icons.check_circle), findsNothing);
    });
  });

  group('TaskCard long-press menu options', () {
    testWidgets('shows Rename option when onRename provided', (tester) async {
      bool renameCalled = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 200,
            height: 200,
            child: TaskCard(
              task: Task(id: 1, name: 'Task', createdAt: 1000),
              onTap: () {},
              onDelete: () {},
              onRename: () { renameCalled = true; },
            ),
          ),
        ),
      ));

      await tester.longPress(find.byType(TaskCard));
      await tester.pumpAndSettle();

      expect(find.text('Rename'), findsOneWidget);
      await tester.tap(find.text('Rename'));
      await tester.pumpAndSettle();
      expect(renameCalled, isTrue);
    });

    testWidgets('shows "Also show under..." when onAddParent provided', (tester) async {
      bool addParentCalled = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 200,
            height: 200,
            child: TaskCard(
              task: Task(id: 1, name: 'Task', createdAt: 1000),
              onTap: () {},
              onDelete: () {},
              onAddParent: () { addParentCalled = true; },
            ),
          ),
        ),
      ));

      await tester.longPress(find.byType(TaskCard));
      await tester.pumpAndSettle();

      expect(find.text('Also show under...'), findsOneWidget);
      await tester.tap(find.text('Also show under...'));
      await tester.pumpAndSettle();
      expect(addParentCalled, isTrue);
    });

    testWidgets('shows "Do after..." when onAddDependency provided', (tester) async {
      bool depCalled = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 200,
            height: 200,
            child: TaskCard(
              task: Task(id: 1, name: 'Task', createdAt: 1000),
              onTap: () {},
              onDelete: () {},
              onAddDependency: () { depCalled = true; },
            ),
          ),
        ),
      ));

      await tester.longPress(find.byType(TaskCard));
      await tester.pumpAndSettle();

      expect(find.text('Do after...'), findsOneWidget);
      await tester.tap(find.text('Do after...'));
      await tester.pumpAndSettle();
      expect(depCalled, isTrue);
    });

    testWidgets('shows Schedule option when onSchedule provided', (tester) async {
      bool scheduleCalled = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 200,
            height: 200,
            child: TaskCard(
              task: Task(id: 1, name: 'Task', createdAt: 1000),
              onTap: () {},
              onDelete: () {},
              onSchedule: () { scheduleCalled = true; },
            ),
          ),
        ),
      ));

      await tester.longPress(find.byType(TaskCard));
      await tester.pumpAndSettle();

      expect(find.text('Schedule'), findsOneWidget);
      await tester.tap(find.text('Schedule'));
      await tester.pumpAndSettle();
      expect(scheduleCalled, isTrue);
    });

    testWidgets('shows "Move to..." when onMove provided', (tester) async {
      bool moveCalled = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 200,
            height: 200,
            child: TaskCard(
              task: Task(id: 1, name: 'Task', createdAt: 1000),
              onTap: () {},
              onDelete: () {},
              onMove: () { moveCalled = true; },
            ),
          ),
        ),
      ));

      await tester.longPress(find.byType(TaskCard));
      await tester.pumpAndSettle();

      expect(find.text('Move to...'), findsOneWidget);
      await tester.tap(find.text('Move to...'));
      await tester.pumpAndSettle();
      expect(moveCalled, isTrue);
    });

    testWidgets('shows "Remove from here" when onUnlink provided', (tester) async {
      bool unlinkCalled = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 200,
            height: 200,
            child: TaskCard(
              task: Task(id: 1, name: 'Task', createdAt: 1000),
              onTap: () {},
              onDelete: () {},
              onUnlink: () { unlinkCalled = true; },
            ),
          ),
        ),
      ));

      await tester.longPress(find.byType(TaskCard));
      await tester.pumpAndSettle();

      expect(find.text('Remove from here'), findsOneWidget);
      await tester.tap(find.text('Remove from here'));
      await tester.pumpAndSettle();
      expect(unlinkCalled, isTrue);
    });

    testWidgets('always shows delete option', (tester) async {
      bool deleteCalled = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 200,
            height: 200,
            child: TaskCard(
              task: Task(id: 1, name: 'My Task', createdAt: 1000),
              onTap: () {},
              onDelete: () { deleteCalled = true; },
            ),
          ),
        ),
      ));

      await tester.longPress(find.byType(TaskCard));
      await tester.pumpAndSettle();

      expect(find.text('Delete "My Task"'), findsOneWidget);
      await tester.tap(find.text('Delete "My Task"'));
      await tester.pumpAndSettle();
      expect(deleteCalled, isTrue);
    });

    testWidgets('hides optional menu items when callbacks are null', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 200,
            height: 200,
            child: TaskCard(
              task: Task(id: 1, name: 'Minimal', createdAt: 1000),
              onTap: () {},
              onDelete: () {},
              // All optional callbacks null
            ),
          ),
        ),
      ));

      await tester.longPress(find.byType(TaskCard));
      await tester.pumpAndSettle();

      expect(find.text('Rename'), findsNothing);
      expect(find.text('Also show under...'), findsNothing);
      expect(find.text('Do after...'), findsNothing);
      expect(find.text('Schedule'), findsNothing);
      expect(find.text('Move to...'), findsNothing);
      expect(find.text('Remove from here'), findsNothing);
      expect(find.text('Stop working'), findsNothing);
      // Delete is always shown
      expect(find.text('Delete "Minimal"'), findsOneWidget);
    });
  });

  group('TaskCard someday badge', () {
    testWidgets('shows bedtime icon when isSomeday is true', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        task: Task(id: 1, name: 'Someday task', createdAt: 1000, isSomeday: true),
      ));

      expect(find.byIcon(Icons.bedtime), findsOneWidget);
    });

    testWidgets('no bedtime icon when isSomeday is false', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        task: Task(id: 1, name: 'Normal task', createdAt: 1000),
      ));

      expect(find.byIcon(Icons.bedtime), findsNothing);
    });
  });
}
