import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:task_roulette/models/task.dart';
import 'package:task_roulette/widgets/leaf_task_detail.dart';

void main() {
  Widget buildTestWidget({
    required Task task,
    VoidCallback? onDone,
    VoidCallback? onSkip,
    VoidCallback? onToggleStarted,
    VoidCallback? onRename,
    void Function(String?)? onUpdateUrl,
    ValueChanged<int>? onUpdatePriority,
    ValueChanged<int>? onUpdateDifficulty,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: LeafTaskDetail(
          task: task,
          onDone: onDone ?? () {},
          onSkip: onSkip ?? () {},
          onToggleStarted: onToggleStarted ?? () {},
          onRename: onRename ?? () {},
          onUpdateUrl: onUpdateUrl ?? (_) {},
          onUpdatePriority: onUpdatePriority ?? (_) {},
          onUpdateDifficulty: onUpdateDifficulty ?? (_) {},
        ),
      ),
    );
  }

  group('LeafTaskDetail', () {
    testWidgets('does not show creation date', (tester) async {
      final now = DateTime.now();
      await tester.pumpWidget(buildTestWidget(
        task: Task(id: 1, name: 'Task', createdAt: now.millisecondsSinceEpoch),
      ));

      expect(find.text('${now.day}/${now.month}/${now.year}'), findsNothing);
    });

    testWidgets('displays task name', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        task: Task(id: 1, name: 'Write report', createdAt: DateTime.now().millisecondsSinceEpoch),
      ));

      expect(find.text('Write report'), findsOneWidget);
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

    testWidgets('does not show Add link placeholder when no URL', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        task: Task(id: 1, name: 'Task', createdAt: DateTime.now().millisecondsSinceEpoch),
      ));

      expect(find.text('Add link'), findsNothing);
    });

    testWidgets('URL row hidden when no URL', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        task: Task(id: 1, name: 'Task', createdAt: DateTime.now().millisecondsSinceEpoch),
      ));

      expect(find.byIcon(Icons.link), findsNothing);
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

    testWidgets('shows Start working button when task is not started', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        task: Task(id: 1, name: 'Task', createdAt: DateTime.now().millisecondsSinceEpoch),
      ));

      expect(find.text('Start working'), findsOneWidget);
    });

    testWidgets('shows Started chip when task is started', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        task: Task(
          id: 1,
          name: 'Task',
          createdAt: DateTime.now().millisecondsSinceEpoch,
          startedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      ));

      expect(find.textContaining('Started'), findsOneWidget);
      expect(find.text('Start working'), findsNothing);
    });

    testWidgets('shows "Started just now" inside chip for recently started task', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        task: Task(
          id: 1,
          name: 'Task',
          createdAt: DateTime.now().millisecondsSinceEpoch,
          startedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      ));

      expect(find.textContaining('just now'), findsOneWidget);
    });

    testWidgets('shows compact time ago for started task', (tester) async {
      final twoHoursAgo = DateTime.now().subtract(const Duration(hours: 2));
      await tester.pumpWidget(buildTestWidget(
        task: Task(
          id: 1,
          name: 'Task',
          createdAt: DateTime.now().millisecondsSinceEpoch,
          startedAt: twoHoursAgo.millisecondsSinceEpoch,
        ),
      ));

      expect(find.textContaining('2h ago'), findsOneWidget);
    });

    testWidgets('Start working chip fires onToggleStarted', (tester) async {
      var toggled = false;
      await tester.pumpWidget(buildTestWidget(
        task: Task(id: 1, name: 'Task', createdAt: DateTime.now().millisecondsSinceEpoch),
        onToggleStarted: () => toggled = true,
      ));

      await tester.tap(find.text('Start working'));
      expect(toggled, isTrue);
    });

    testWidgets('Started chip fires onToggleStarted', (tester) async {
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

      await tester.tap(find.textContaining('Started'));
      expect(toggled, isTrue);
    });

    testWidgets('shows Skip as plain TextButton without icon', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        task: Task(id: 1, name: 'Task', createdAt: DateTime.now().millisecondsSinceEpoch),
      ));

      expect(find.text('Skip'), findsOneWidget);
      expect(find.byIcon(Icons.not_interested), findsNothing);
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

    testWidgets('displays URL when task has one', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        task: Task(
          id: 1,
          name: 'Task',
          createdAt: DateTime.now().millisecondsSinceEpoch,
          url: 'https://example.com',
        ),
      ));

      expect(find.textContaining('example.com'), findsOneWidget);
      expect(find.byIcon(Icons.link), findsOneWidget);
    });

    testWidgets('Start working button is an ActionChip', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        task: Task(id: 1, name: 'Task', createdAt: DateTime.now().millisecondsSinceEpoch),
      ));

      expect(find.widgetWithText(ActionChip, 'Start working'), findsOneWidget);
    });

    testWidgets('showEditUrlDialog static method shows dialog', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () {
                LeafTaskDetail.showEditUrlDialog(
                  context,
                  'https://test.com',
                  (_) {},
                );
              },
              child: const Text('Open dialog'),
            ),
          ),
        ),
      ));

      await tester.tap(find.text('Open dialog'));
      await tester.pumpAndSettle();

      expect(find.text('Link'), findsOneWidget);
      expect(find.text('Save'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.text('Remove'), findsOneWidget);
    });

    testWidgets('shows priority flag icon (outlined when normal)', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        task: Task(id: 1, name: 'Task', createdAt: DateTime.now().millisecondsSinceEpoch),
      ));

      expect(find.byIcon(Icons.flag_outlined), findsOneWidget);
      expect(find.byIcon(Icons.flag), findsNothing);
    });

    testWidgets('shows difficulty segmented button with default selection', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        task: Task(id: 1, name: 'Task', createdAt: DateTime.now().millisecondsSinceEpoch),
      ));

      expect(find.text('Difficulty'), findsOneWidget);
      expect(find.text('Easy'), findsOneWidget);
      expect(find.text('Hard'), findsOneWidget);
    });

    testWidgets('tapping priority flag fires onUpdatePriority with 1', (tester) async {
      int? newPriority;
      await tester.pumpWidget(buildTestWidget(
        task: Task(id: 1, name: 'Task', createdAt: DateTime.now().millisecondsSinceEpoch),
        onUpdatePriority: (p) => newPriority = p,
      ));

      await tester.tap(find.byIcon(Icons.flag_outlined));
      expect(newPriority, 1);
    });

    testWidgets('tapping difficulty option fires onUpdateDifficulty', (tester) async {
      int? newDifficulty;
      await tester.pumpWidget(buildTestWidget(
        task: Task(id: 1, name: 'Task', createdAt: DateTime.now().millisecondsSinceEpoch),
        onUpdateDifficulty: (d) => newDifficulty = d,
      ));

      await tester.tap(find.text('Easy'));
      expect(newDifficulty, 0);
    });

    testWidgets('shows filled flag icon when high priority', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        task: Task(id: 1, name: 'Task', createdAt: DateTime.now().millisecondsSinceEpoch, priority: 1),
      ));

      expect(find.byIcon(Icons.flag), findsOneWidget);
      expect(find.byIcon(Icons.flag_outlined), findsNothing);
    });

    testWidgets('difficulty shows correct selection for non-default value', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        task: Task(id: 1, name: 'Task', createdAt: DateTime.now().millisecondsSinceEpoch, difficulty: 0),
      ));

      expect(find.text('Easy'), findsOneWidget);
      expect(find.text('Hard'), findsOneWidget);
    });
  });
}
