import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:task_roulette/models/task_schedule.dart';
import 'package:task_roulette/widgets/schedule_dialog.dart';

void main() {
  Widget buildTestApp({
    required int taskId,
    List<TaskSchedule> currentSchedules = const [],
    Set<int> inheritedDays = const {},
    bool isCurrentlyOverriding = false,
    List<ScheduleSource> sources = const [],
  }) {
    return MaterialApp(
      home: Scaffold(
        body: ScheduleDialog(
          taskId: taskId,
          currentSchedules: currentSchedules,
          inheritedDays: inheritedDays,
          isCurrentlyOverriding: isCurrentlyOverriding,
          sources: sources,
        ),
      ),
    );
  }

  group('ScheduleDialog rendering', () {
    testWidgets('shows all 7 day chips', (tester) async {
      await tester.pumpWidget(buildTestApp(taskId: 1));

      for (final day in ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']) {
        expect(find.text(day), findsOneWidget);
      }
    });

    testWidgets('shows Schedule header with event icon', (tester) async {
      await tester.pumpWidget(buildTestApp(taskId: 1));

      expect(find.text('Schedule'), findsOneWidget);
      expect(find.byIcon(Icons.event), findsOneWidget);
    });

    testWidgets('Save button disabled when no changes', (tester) async {
      await tester.pumpWidget(buildTestApp(taskId: 1));

      final button = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'));
      expect(button.onPressed, isNull);
    });

    testWidgets('Save button enabled after selecting a day', (tester) async {
      await tester.pumpWidget(buildTestApp(taskId: 1));

      await tester.tap(find.text('Mon'));
      await tester.pump();

      final button = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'));
      expect(button.onPressed, isNotNull);
    });

    testWidgets('pre-selects days from currentSchedules', (tester) async {
      await tester.pumpWidget(buildTestApp(
        taskId: 1,
        currentSchedules: [
          TaskSchedule(taskId: 1, dayOfWeek: 1),
          TaskSchedule(taskId: 1, dayOfWeek: 5),
        ],
      ));

      // Mon and Fri chips should be selected (FilterChip.selected = true)
      final monChip = tester.widget<FilterChip>(
        find.widgetWithText(FilterChip, 'Mon'),
      );
      expect(monChip.selected, isTrue);

      final friChip = tester.widget<FilterChip>(
        find.widgetWithText(FilterChip, 'Fri'),
      );
      expect(friChip.selected, isTrue);

      // Wed should not be selected
      final wedChip = tester.widget<FilterChip>(
        find.widgetWithText(FilterChip, 'Wed'),
      );
      expect(wedChip.selected, isFalse);
    });

    testWidgets('toggling a day on then off re-disables Save', (tester) async {
      await tester.pumpWidget(buildTestApp(taskId: 1));

      await tester.tap(find.text('Tue'));
      await tester.pump();
      // Save should be enabled
      var button = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'));
      expect(button.onPressed, isNotNull);

      // Toggle off
      await tester.tap(find.text('Tue'));
      await tester.pump();
      button = tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'));
      expect(button.onPressed, isNull);
    });
  });

  group('ScheduleDialog source labels', () {
    testWidgets('shows "Repeat weekly" when no sources', (tester) async {
      await tester.pumpWidget(buildTestApp(taskId: 1));

      expect(find.text('Repeat weekly'), findsOneWidget);
    });

    testWidgets('shows "Inherited from:" when inheriting', (tester) async {
      await tester.pumpWidget(buildTestApp(
        taskId: 1,
        inheritedDays: {1, 3},
        sources: [(id: 10, name: 'Work', days: {1, 3})],
      ));

      expect(find.text('Inherited from: Work'), findsOneWidget);
    });

    testWidgets('shows "Custom schedule" when overriding with sources', (tester) async {
      await tester.pumpWidget(buildTestApp(
        taskId: 1,
        currentSchedules: [TaskSchedule(taskId: 1, dayOfWeek: 5)],
        inheritedDays: {1},
        isCurrentlyOverriding: true,
        sources: [(id: 10, name: 'Work', days: {1})],
      ));

      expect(find.text('Custom schedule'), findsOneWidget);
    });
  });

  group('ScheduleDialog inherited mode', () {
    testWidgets('shows inherited days as selected chips', (tester) async {
      await tester.pumpWidget(buildTestApp(
        taskId: 1,
        inheritedDays: {1, 5},
        sources: [(id: 10, name: 'Work', days: {1, 5})],
      ));

      final monChip = tester.widget<FilterChip>(
        find.widgetWithText(FilterChip, 'Mon'),
      );
      expect(monChip.selected, isTrue);

      final wedChip = tester.widget<FilterChip>(
        find.widgetWithText(FilterChip, 'Wed'),
      );
      expect(wedChip.selected, isFalse);
    });

    testWidgets('tapping inherited chip switches to override mode', (tester) async {
      await tester.pumpWidget(buildTestApp(
        taskId: 1,
        inheritedDays: {1, 5},
        sources: [(id: 10, name: 'Work', days: {1, 5})],
      ));

      // Initially shows "Inherited from:"
      expect(find.text('Inherited from: Work'), findsOneWidget);

      // Tap Mon (inherited day) → switches to override, toggles Mon off
      await tester.tap(find.text('Mon'));
      await tester.pump();

      // Should now show override label
      expect(find.text('Custom schedule'), findsOneWidget);
    });

    testWidgets('Clear all in inherited mode switches to empty override', (tester) async {
      await tester.pumpWidget(buildTestApp(
        taskId: 1,
        inheritedDays: {1},
        sources: [(id: 10, name: 'Work', days: {1})],
      ));

      await tester.tap(find.text('Clear all'));
      await tester.pump();

      // Should switch to override mode with no days selected
      expect(find.text('Custom schedule'), findsOneWidget);
    });
  });

  group('ScheduleDialog override mode', () {
    testWidgets('shows Clear override button when overriding with inherited days', (tester) async {
      await tester.pumpWidget(buildTestApp(
        taskId: 1,
        currentSchedules: [TaskSchedule(taskId: 1, dayOfWeek: 3)],
        inheritedDays: {1},
        isCurrentlyOverriding: true,
        sources: [(id: 10, name: 'Work', days: {1})],
      ));

      expect(find.text('Clear override'), findsOneWidget);
    });

    testWidgets('Clear override restores inherited mode', (tester) async {
      await tester.pumpWidget(buildTestApp(
        taskId: 1,
        currentSchedules: [TaskSchedule(taskId: 1, dayOfWeek: 3)],
        inheritedDays: {1},
        isCurrentlyOverriding: true,
        sources: [(id: 10, name: 'Work', days: {1})],
      ));

      await tester.tap(find.text('Clear override'));
      await tester.pump();

      expect(find.text('Inherited from: Work'), findsOneWidget);
    });
  });

  group('ScheduleDialogResult', () {
    test('constructor stores fields', () {
      final result = ScheduleDialogResult(
        schedules: [TaskSchedule(taskId: 1, dayOfWeek: 2)],
        isOverride: true,
      );
      expect(result.schedules.length, 1);
      expect(result.isOverride, isTrue);
    });

    test('constructor stores deadline field', () {
      final result = ScheduleDialogResult(
        schedules: [],
        isOverride: false,
        deadline: '2026-03-25',
      );
      expect(result.deadline, '2026-03-25');
    });
  });

  group('Deadline section', () {
    testWidgets('shows "Set deadline" when no deadline', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ScheduleDialog(
            taskId: 1,
            currentSchedules: const [],
          ),
        ),
      ));

      expect(find.text('Set deadline'), findsOneWidget);
      expect(find.byIcon(Icons.event_available), findsOneWidget);
    });

    testWidgets('shows formatted date when deadline is set', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ScheduleDialog(
            taskId: 1,
            currentSchedules: const [],
            currentDeadline: '2026-03-25',
          ),
        ),
      ));

      expect(find.text('Due by: Mar 25, 2026'), findsOneWidget);
      expect(find.byIcon(Icons.close), findsOneWidget); // clear button
    });

    testWidgets('shows inherited deadline as read-only', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ScheduleDialog(
            taskId: 1,
            currentSchedules: const [],
            inheritedDeadline: (deadline: '2026-03-20', deadlineType: 'due_by', sourceName: 'Project X'),
          ),
        ),
      ));

      expect(find.text('Due by: Mar 20, 2026'), findsOneWidget);
      expect(find.text('Inherited from: Project X'), findsOneWidget);
      // Should NOT show clear button for inherited deadline
      expect(find.byIcon(Icons.close), findsNothing);
    });

    testWidgets('own deadline shown instead of inherited when both exist', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ScheduleDialog(
            taskId: 1,
            currentSchedules: const [],
            currentDeadline: '2026-03-22',
            inheritedDeadline: (deadline: '2026-03-20', deadlineType: 'due_by', sourceName: 'Project X'),
          ),
        ),
      ));

      // Own deadline shown (editable)
      expect(find.text('Due by: Mar 22, 2026'), findsOneWidget);
      expect(find.byIcon(Icons.close), findsOneWidget);
      // Inherited not shown
      expect(find.text('Inherited from: Project X'), findsNothing);
    });

    testWidgets('Save enabled when only deadline changes', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ScheduleDialog(
            taskId: 1,
            currentSchedules: const [],
            currentDeadline: '2026-03-25',
          ),
        ),
      ));

      // Save should be disabled initially (no changes)
      final saveButton = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Save'),
      );
      expect(saveButton.onPressed, isNull);

      // Tap clear to remove deadline
      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();

      // Save should now be enabled
      final saveButton2 = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Save'),
      );
      expect(saveButton2.onPressed, isNotNull);
    });
  });
}
