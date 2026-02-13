import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:task_roulette/models/task.dart';
import 'package:task_roulette/widgets/task_card.dart';

void main() {
  Widget buildTestWidget({
    required Task task,
    bool hasStartedDescendant = false,
    int indicatorStyle = 2,
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
            indicatorStyle: indicatorStyle,
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

    testWidgets('indicator style 0 shows dot instead of play icon', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        task: Task(id: 1, name: 'WIP', createdAt: 1000, startedAt: 2000),
        indicatorStyle: 0,
      ));

      expect(find.byIcon(Icons.play_circle_filled), findsNothing);
      // Dot is a Container with BoxShape.circle — verify no play icon is shown
    });

    testWidgets('indicator style 1 shows border instead of play icon', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        task: Task(id: 1, name: 'WIP', createdAt: 1000, startedAt: 2000),
        indicatorStyle: 1,
      ));

      expect(find.byIcon(Icons.play_circle_filled), findsNothing);
    });
  });
}
