import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:task_roulette/models/task.dart';
import 'package:task_roulette/widgets/task_card.dart';

void main() {
  Widget buildTestWidget({
    required Task task,
    bool hasStartedDescendant = false,
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
            hasStartedDescendant: hasStartedDescendant,
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

    testWidgets('shows play icon when hasStartedDescendant is true', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        task: Task(id: 1, name: 'Parent', createdAt: 1000),
        hasStartedDescendant: true,
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
}
