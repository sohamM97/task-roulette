import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:task_roulette/models/task.dart';
import 'package:task_roulette/widgets/leaf_task_detail.dart';

void main() {
  Widget buildTestWidget({
    required Task task,
    List<String> parentNames = const [],
    VoidCallback? onDone,
    VoidCallback? onAddParent,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: LeafTaskDetail(
          task: task,
          parentNames: parentNames,
          onDone: onDone ?? () {},
          onAddParent: onAddParent ?? () {},
        ),
      ),
    );
  }

  group('LeafTaskDetail', () {
    testWidgets('displays task name', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        task: Task(id: 1, name: 'Write report', createdAt: DateTime.now().millisecondsSinceEpoch),
      ));

      expect(find.text('Write report'), findsOneWidget);
    });

    testWidgets('displays "Created today" for today\'s task', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        task: Task(id: 1, name: 'New task', createdAt: DateTime.now().millisecondsSinceEpoch),
      ));

      expect(find.text('Created today'), findsOneWidget);
    });

    testWidgets('displays "Created yesterday" for yesterday\'s task', (tester) async {
      final yesterday = DateTime.now().subtract(const Duration(days: 1));
      await tester.pumpWidget(buildTestWidget(
        task: Task(id: 1, name: 'Old task', createdAt: yesterday.millisecondsSinceEpoch),
      ));

      expect(find.text('Created yesterday'), findsOneWidget);
    });

    testWidgets('displays relative days for recent tasks', (tester) async {
      final threeDaysAgo = DateTime.now().subtract(const Duration(days: 3));
      await tester.pumpWidget(buildTestWidget(
        task: Task(id: 1, name: 'Task', createdAt: threeDaysAgo.millisecondsSinceEpoch),
      ));

      expect(find.text('Created 3 days ago'), findsOneWidget);
    });

    testWidgets('displays parent names with "Listed under"', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        task: Task(id: 1, name: 'Sub task', createdAt: DateTime.now().millisecondsSinceEpoch),
        parentNames: ['Project A', 'Sprint 1'],
      ));

      expect(find.text('Listed under Project A, Sprint 1'), findsOneWidget);
    });

    testWidgets('displays "Top-level task" when no parents', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        task: Task(id: 1, name: 'Root task', createdAt: DateTime.now().millisecondsSinceEpoch),
        parentNames: [],
      ));

      expect(find.text('Top-level task'), findsOneWidget);
    });

    testWidgets('Done button fires onDone callback', (tester) async {
      var doneTapped = false;
      await tester.pumpWidget(buildTestWidget(
        task: Task(id: 1, name: 'Task', createdAt: DateTime.now().millisecondsSinceEpoch),
        onDone: () => doneTapped = true,
      ));

      await tester.tap(find.text('Done'));
      expect(doneTapped, isTrue);
    });

    testWidgets('tapping parent area fires onAddParent callback', (tester) async {
      var addParentTapped = false;
      await tester.pumpWidget(buildTestWidget(
        task: Task(id: 1, name: 'Task', createdAt: DateTime.now().millisecondsSinceEpoch),
        parentNames: ['Parent A'],
        onAddParent: () => addParentTapped = true,
      ));

      await tester.tap(find.text('Listed under Parent A'));
      expect(addParentTapped, isTrue);
    });

    testWidgets('shows subtask hint', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        task: Task(id: 1, name: 'Task', createdAt: DateTime.now().millisecondsSinceEpoch),
      ));

      expect(find.text('Tap + to break this into subtasks'), findsOneWidget);
    });

    testWidgets('shows add parent icon', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        task: Task(id: 1, name: 'Task', createdAt: DateTime.now().millisecondsSinceEpoch),
      ));

      expect(find.byIcon(Icons.add_circle_outline), findsOneWidget);
    });
  });
}
