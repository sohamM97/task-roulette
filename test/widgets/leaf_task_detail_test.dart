import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:task_roulette/models/task.dart';
import 'package:task_roulette/widgets/leaf_task_detail.dart';

void main() {
  Widget buildTestWidget({
    required Task task,
    List<String> parentNames = const [],
    VoidCallback? onDone,
    VoidCallback? onSkip,
    VoidCallback? onAddParent,
    VoidCallback? onToggleStarted,
    VoidCallback? onRename,
    void Function(String?)? onUpdateUrl,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: LeafTaskDetail(
          task: task,
          parentNames: parentNames,
          onDone: onDone ?? () {},
          onSkip: onSkip ?? () {},
          onAddParent: onAddParent ?? () {},
          onToggleStarted: onToggleStarted ?? () {},
          onRename: onRename ?? () {},
          onUpdateUrl: onUpdateUrl ?? (_) {},
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

    testWidgets('shows "Start working" button when task is not started', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        task: Task(id: 1, name: 'Task', createdAt: DateTime.now().millisecondsSinceEpoch),
      ));

      expect(find.text('Start working'), findsOneWidget);
      expect(find.text('Started'), findsNothing);
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    });

    testWidgets('shows "Started" button when task is started', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        task: Task(
          id: 1,
          name: 'Task',
          createdAt: DateTime.now().millisecondsSinceEpoch,
          startedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      ));

      expect(find.text('Started'), findsOneWidget);
      expect(find.text('Start working'), findsNothing);
    });

    testWidgets('shows "Started just now" for recently started task', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        task: Task(
          id: 1,
          name: 'Task',
          createdAt: DateTime.now().millisecondsSinceEpoch,
          startedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      ));

      expect(find.text('Started just now'), findsOneWidget);
    });

    testWidgets('shows time ago for started task', (tester) async {
      final twoHoursAgo = DateTime.now().subtract(const Duration(hours: 2));
      await tester.pumpWidget(buildTestWidget(
        task: Task(
          id: 1,
          name: 'Task',
          createdAt: DateTime.now().millisecondsSinceEpoch,
          startedAt: twoHoursAgo.millisecondsSinceEpoch,
        ),
      ));

      expect(find.text('Started 2 hours ago'), findsOneWidget);
    });

    testWidgets('Start working button fires onToggleStarted', (tester) async {
      var toggled = false;
      await tester.pumpWidget(buildTestWidget(
        task: Task(id: 1, name: 'Task', createdAt: DateTime.now().millisecondsSinceEpoch),
        onToggleStarted: () => toggled = true,
      ));

      await tester.tap(find.text('Start working'));
      expect(toggled, isTrue);
    });

    testWidgets('Started button fires onToggleStarted', (tester) async {
      var toggled = false;
      await tester.pumpWidget(buildTestWidget(
        task: Task(
          id: 1,
          name: 'Task',
          createdAt: DateTime.now().millisecondsSinceEpoch,
          startedAt: DateTime.now().millisecondsSinceEpoch,
        ),
        onToggleStarted: () => toggled = true,
      ));

      await tester.tap(find.text('Started'));
      expect(toggled, isTrue);
    });

    testWidgets('shows Skip button', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        task: Task(id: 1, name: 'Task', createdAt: DateTime.now().millisecondsSinceEpoch),
      ));

      expect(find.text('Skip'), findsOneWidget);
      expect(find.byIcon(Icons.not_interested), findsOneWidget);
    });

    testWidgets('Skip button fires onSkip callback', (tester) async {
      var skipped = false;
      await tester.pumpWidget(buildTestWidget(
        task: Task(id: 1, name: 'Task', createdAt: DateTime.now().millisecondsSinceEpoch),
        onSkip: () => skipped = true,
      ));

      await tester.tap(find.text('Skip'));
      expect(skipped, isTrue);
    });

    testWidgets('shows edit icon next to task name', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        task: Task(id: 1, name: 'Task', createdAt: DateTime.now().millisecondsSinceEpoch),
      ));

      expect(find.byIcon(Icons.edit), findsOneWidget);
    });

    testWidgets('tapping task name fires onRename callback', (tester) async {
      var renamed = false;
      await tester.pumpWidget(buildTestWidget(
        task: Task(id: 1, name: 'My Task', createdAt: DateTime.now().millisecondsSinceEpoch),
        onRename: () => renamed = true,
      ));

      await tester.tap(find.text('My Task'));
      expect(renamed, isTrue);
    });
  });
}
