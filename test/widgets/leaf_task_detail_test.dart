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
    ValueChanged<int>? onUpdateQuickTask,
    VoidCallback? onWorkedOn,
    VoidCallback? onUndoWorkedOn,
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
          onUpdateQuickTask: onUpdateQuickTask ?? (_) {},
          onWorkedOn: onWorkedOn,
          onUndoWorkedOn: onUndoWorkedOn,
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

    testWidgets('shows add_link icon when no URL', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        task: Task(id: 1, name: 'Task', createdAt: DateTime.now().millisecondsSinceEpoch),
      ));

      expect(find.byIcon(Icons.add_link), findsOneWidget);
      expect(find.byIcon(Icons.link), findsNothing);
    });

    testWidgets('shows link icon when URL is set', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        task: Task(
          id: 1,
          name: 'Task',
          createdAt: DateTime.now().millisecondsSinceEpoch,
          url: 'https://example.com',
        ),
      ));

      expect(find.byIcon(Icons.link), findsOneWidget);
      expect(find.byIcon(Icons.add_link), findsNothing);
    });

    testWidgets('"Done for good!" fires onDone callback', (tester) async {
      var doneTapped = false;
      await tester.pumpWidget(buildTestWidget(
        task: Task(id: 1, name: 'Task', createdAt: DateTime.now().millisecondsSinceEpoch),
        onDone: () => doneTapped = true,
      ));

      await tester.tap(find.text('Done for good!'));
      expect(doneTapped, isTrue);
    });

    testWidgets('shows Start button when task is not started', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        task: Task(id: 1, name: 'Task', createdAt: DateTime.now().millisecondsSinceEpoch),
      ));

      expect(find.text('Start'), findsOneWidget);
    });

    testWidgets('shows Started text when task is started', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        task: Task(
          id: 1,
          name: 'Task',
          createdAt: DateTime.now().millisecondsSinceEpoch,
          startedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      ));

      expect(find.textContaining('Started'), findsOneWidget);
      expect(find.text('Start'), findsNothing);
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

    testWidgets('Start button fires onToggleStarted', (tester) async {
      var toggled = false;
      await tester.pumpWidget(buildTestWidget(
        task: Task(id: 1, name: 'Task', createdAt: DateTime.now().millisecondsSinceEpoch),
        onToggleStarted: () => toggled = true,
      ));

      await tester.tap(find.text('Start'));
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

    testWidgets('shows Skip as TextButton with skip_next icon', (tester) async {
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

    testWidgets('URL shown as icon with tooltip, not as text row', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        task: Task(
          id: 1,
          name: 'Task',
          createdAt: DateTime.now().millisecondsSinceEpoch,
          url: 'https://example.com',
        ),
      ));

      // URL text should not be visible — it's in the tooltip
      expect(find.text('example.com'), findsNothing);
      // But the link icon should be shown
      expect(find.byIcon(Icons.link), findsOneWidget);
    });

    testWidgets('Start button is a TextButton', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        task: Task(id: 1, name: 'Task', createdAt: DateTime.now().millisecondsSinceEpoch),
      ));

      expect(find.widgetWithText(TextButton, 'Start'), findsOneWidget);
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

    testWidgets('shows bolt icon for quick task toggle', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        task: Task(id: 1, name: 'Task', createdAt: DateTime.now().millisecondsSinceEpoch),
      ));

      // Should show outlined bolt (not quick task by default)
      expect(find.byIcon(Icons.bolt_outlined), findsOneWidget);
    });

    testWidgets('shows filled bolt icon when task is quick', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        task: Task(id: 1, name: 'Task', createdAt: DateTime.now().millisecondsSinceEpoch, difficulty: 1),
      ));

      expect(find.byIcon(Icons.bolt), findsOneWidget);
      expect(find.byIcon(Icons.bolt_outlined), findsNothing);
    });

    testWidgets('tapping bolt icon fires onUpdateQuickTask with 1', (tester) async {
      int? newQuick;
      await tester.pumpWidget(buildTestWidget(
        task: Task(id: 1, name: 'Task', createdAt: DateTime.now().millisecondsSinceEpoch),
        onUpdateQuickTask: (q) => newQuick = q,
      ));

      await tester.tap(find.byIcon(Icons.bolt_outlined));
      expect(newQuick, 1);
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

    testWidgets('shows filled flag icon when high priority', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        task: Task(id: 1, name: 'Task', createdAt: DateTime.now().millisecondsSinceEpoch, priority: 1),
      ));

      expect(find.byIcon(Icons.flag), findsOneWidget);
      expect(find.byIcon(Icons.flag_outlined), findsNothing);
    });

    testWidgets('shows "Done today" when not worked on today', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        task: Task(id: 1, name: 'Task', createdAt: DateTime.now().millisecondsSinceEpoch),
        onWorkedOn: () {},
      ));

      expect(find.text('Done today'), findsOneWidget);
      expect(find.text('Worked on today'), findsNothing);
      expect(find.text('Done for good!'), findsOneWidget);
    });

    testWidgets('shows "Worked on today" when already worked on today', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        task: Task(
          id: 1,
          name: 'Task',
          createdAt: DateTime.now().millisecondsSinceEpoch,
          lastWorkedAt: DateTime.now().millisecondsSinceEpoch,
        ),
        onWorkedOn: () {},
        onUndoWorkedOn: () {},
      ));

      expect(find.text('Worked on today'), findsOneWidget);
      expect(find.text('Done today'), findsNothing);
    });

    testWidgets('shows "Done today" when lastWorkedAt is yesterday', (tester) async {
      final yesterday = DateTime.now().subtract(const Duration(days: 1));
      await tester.pumpWidget(buildTestWidget(
        task: Task(
          id: 1,
          name: 'Task',
          createdAt: DateTime.now().millisecondsSinceEpoch,
          lastWorkedAt: yesterday.millisecondsSinceEpoch,
        ),
        onWorkedOn: () {},
      ));

      expect(find.text('Done today'), findsOneWidget);
      expect(find.text('Worked on today'), findsNothing);
    });

    testWidgets('"Done today" fires onWorkedOn callback', (tester) async {
      var workedOn = false;
      await tester.pumpWidget(buildTestWidget(
        task: Task(id: 1, name: 'Task', createdAt: DateTime.now().millisecondsSinceEpoch),
        onWorkedOn: () => workedOn = true,
      ));

      await tester.tap(find.text('Done today'));
      expect(workedOn, isTrue);
    });

    testWidgets('"Worked on today" fires onUndoWorkedOn callback', (tester) async {
      var undone = false;
      await tester.pumpWidget(buildTestWidget(
        task: Task(
          id: 1,
          name: 'Task',
          createdAt: DateTime.now().millisecondsSinceEpoch,
          lastWorkedAt: DateTime.now().millisecondsSinceEpoch,
        ),
        onWorkedOn: () {},
        onUndoWorkedOn: () => undone = true,
      ));

      await tester.tap(find.text('Worked on today'));
      expect(undone, isTrue);
    });

    testWidgets('no repeat icon in chips', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        task: Task(id: 1, name: 'Task', createdAt: DateTime.now().millisecondsSinceEpoch),
      ));

      expect(find.byIcon(Icons.repeat), findsNothing);
    });

    testWidgets('no difficulty segmented button', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        task: Task(id: 1, name: 'Task', createdAt: DateTime.now().millisecondsSinceEpoch),
      ));

      expect(find.text('Difficulty'), findsNothing);
      expect(find.text('Easy'), findsNothing);
      expect(find.text('Hard'), findsNothing);
    });
  });

  group('LeafTaskDetail parent tags', () {
    testWidgets('shows "Under:" and parent names as chips when parentNames provided', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: LeafTaskDetail(
            task: Task(id: 1, name: 'Leaf', createdAt: DateTime.now().millisecondsSinceEpoch),
            onDone: () {},
            onSkip: () {},
            onToggleStarted: () {},
            onRename: () {},
            onUpdateUrl: (_) {},
            onUpdatePriority: (_) {},
            onUpdateQuickTask: (_) {},
            parentNames: const ['Work', 'Personal'],
          ),
        ),
      ));

      expect(find.text('Under:'), findsOneWidget);
      expect(find.text('Work'), findsOneWidget);
      expect(find.text('Personal'), findsOneWidget);
    });

    testWidgets('hides parent tags when parentNames is empty', (tester) async {
      await tester.pumpWidget(buildTestWidget(
        task: Task(id: 1, name: 'Leaf', createdAt: DateTime.now().millisecondsSinceEpoch),
      ));

      // No parent chip containers should appear — just the task name and buttons
      // Verify none of the common parent-related text exists
      expect(find.text('Work'), findsNothing);
      expect(find.text('Personal'), findsNothing);
    });

    testWidgets('shows all parents including the one navigated from', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: LeafTaskDetail(
            task: Task(id: 1, name: 'Leaf', createdAt: DateTime.now().millisecondsSinceEpoch),
            onDone: () {},
            onSkip: () {},
            onToggleStarted: () {},
            onRename: () {},
            onUpdateUrl: (_) {},
            onUpdatePriority: (_) {},
            onUpdateQuickTask: (_) {},
            parentNames: const ['Current Parent', 'Other Parent', 'Third Parent'],
          ),
        ),
      ));

      expect(find.text('Current Parent'), findsOneWidget);
      expect(find.text('Other Parent'), findsOneWidget);
      expect(find.text('Third Parent'), findsOneWidget);
    });
  });
}
