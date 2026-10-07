import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:task_roulette/models/task_schedule.dart';
import 'package:task_roulette/utils/display_utils.dart';
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
      expect(find.byIcon(deadlineIcon), findsOneWidget);
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

    testWidgets('inherited "on" deadline reads "On:"', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ScheduleDialog(
            taskId: 1,
            currentSchedules: const [],
            inheritedDeadline: (deadline: '2026-03-20', deadlineType: 'on', sourceName: 'Trip'),
          ),
        ),
      ));

      expect(find.text('On: Mar 20, 2026'), findsOneWidget);
      expect(find.text('Inherited from: Trip'), findsOneWidget);
    });

    testWidgets('tapping an inherited deadline does not open the calendar', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ScheduleDialog(
            taskId: 1,
            currentSchedules: const [],
            inheritedDeadline: (deadline: '2026-03-20', deadlineType: 'due_by', sourceName: 'Trip'),
          ),
        ),
      ));

      await tester.tap(find.text('Due by: Mar 20, 2026'));
      await tester.pumpAndSettle();

      expect(find.text('Select date'), findsNothing);
    });
  });

  // ---------------------------------------------------------------------------
  // Tests below open the dialog through ScheduleDialog.show, so Save and
  // dismissal pop a real bottom sheet and the returned result can be checked.
  // ---------------------------------------------------------------------------

  const monthNames = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
                      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

  /// Opens the sheet via [ScheduleDialog.show]. The result lands in
  /// [results] once the sheet closes (null entry = cancelled).
  Future<List<ScheduleDialogResult?>> openSheet(
    WidgetTester tester, {
    List<TaskSchedule> currentSchedules = const [],
    Set<int> inheritedDays = const {},
    bool isCurrentlyOverriding = false,
    List<ScheduleSource> sources = const [],
    String? currentDeadline,
    String currentDeadlineType = 'due_by',
  }) async {
    final results = <ScheduleDialogResult?>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              results.add(await ScheduleDialog.show(
                context,
                taskId: 7,
                currentSchedules: currentSchedules,
                inheritedDays: inheritedDays,
                isCurrentlyOverriding: isCurrentlyOverriding,
                sources: sources,
                currentDeadline: currentDeadline,
                currentDeadlineType: currentDeadlineType,
              ));
            },
            child: const Text('Open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    return results;
  }

  Future<void> tapSave(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
  }

  bool saveEnabled(WidgetTester tester) => tester
      .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
      .onPressed != null;

  Set<int> days(ScheduleDialogResult r) =>
      r.schedules.map((s) => s.dayOfWeek).toSet();

  String ymd(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// The 15th of next month: always inside the picker's range (today to
  /// today + 730 days), and "15" appears once in a month grid because the
  /// adjacent-month days shown at its edges are at most 1-6 and 23-31.
  DateTime fifteenthOfNextMonth() {
    final now = DateTime.now();
    return DateTime(now.year, now.month + 1, 15);
  }

  Finder inCalendar(Finder f) =>
      find.descendant(of: find.byType(Dialog), matching: f);

  group('ScheduleDialog.show result', () {
    testWidgets('Save returns the selected days as an override', (tester) async {
      final results = await openSheet(tester);

      await tester.tap(find.text('Mon'));
      await tester.tap(find.text('Wed'));
      await tester.pump();
      await tapSave(tester);

      expect(find.text('Schedule'), findsNothing);
      expect(results, hasLength(1));
      final r = results.single!;
      expect(days(r), {1, 3});
      expect(r.schedules.every((s) => s.taskId == 7), isTrue);
      expect(r.isOverride, isTrue);
      expect(r.deadline, isNull, reason: 'deadline untouched → no change');
      expect(r.deadlineType, isNull);
    });

    testWidgets('dismissing the sheet returns null', (tester) async {
      final results = await openSheet(tester);

      await tester.tap(find.text('Mon'));
      await tester.pump();
      // Tap the modal barrier above the sheet.
      await tester.tapAt(const Offset(400, 20));
      await tester.pumpAndSettle();

      expect(results, [null]);
    });

    testWidgets('tapping an inherited day keeps the other inherited days', (tester) async {
      final results = await openSheet(
        tester,
        inheritedDays: {1, 5},
        sources: [(id: 10, name: 'Work', days: {1, 5})],
      );

      // Mon is inherited: switching to override copies {Mon, Fri}, then
      // toggles Mon off.
      await tester.tap(find.text('Mon'));
      await tester.pump();
      await tapSave(tester);

      expect(days(results.single!), {5});
      expect(results.single!.isOverride, isTrue);
    });

    testWidgets('tapping a non-inherited day adds it to the inherited days', (tester) async {
      final results = await openSheet(
        tester,
        inheritedDays: {1, 5},
        sources: [(id: 10, name: 'Work', days: {1, 5})],
      );

      await tester.tap(find.text('Wed'));
      await tester.pump();
      await tapSave(tester);

      expect(days(results.single!), {1, 3, 5});
    });

    testWidgets('Clear all while inheriting saves an empty override', (tester) async {
      final results = await openSheet(
        tester,
        inheritedDays: {2},
        sources: [(id: 10, name: 'Work', days: {2})],
      );

      await tester.tap(find.text('Clear all'));
      await tester.pump();
      await tapSave(tester);

      final r = results.single!;
      expect(r.schedules, isEmpty);
      expect(r.isOverride, isTrue, reason: 'opting out of the inherited days');
    });

    testWidgets('Clear all on own days saves an empty schedule', (tester) async {
      final results = await openSheet(
        tester,
        currentSchedules: [
          TaskSchedule(taskId: 7, dayOfWeek: 2),
          TaskSchedule(taskId: 7, dayOfWeek: 4),
        ],
      );

      await tester.tap(find.text('Clear all'));
      await tester.pump();
      expect(find.text('Clear all'), findsNothing,
          reason: 'button hides once nothing is selected');
      await tapSave(tester);

      expect(results.single!.schedules, isEmpty);
    });

    testWidgets('Clear override saves isOverride false with no days', (tester) async {
      final results = await openSheet(
        tester,
        currentSchedules: [TaskSchedule(taskId: 7, dayOfWeek: 3)],
        inheritedDays: {1},
        isCurrentlyOverriding: true,
        sources: [(id: 10, name: 'Work', days: {1})],
      );

      await tester.tap(find.text('Clear override'));
      await tester.pump();
      await tapSave(tester);

      final r = results.single!;
      expect(r.isOverride, isFalse, reason: 'restore inheritance');
      expect(r.schedules, isEmpty);
    });

    testWidgets('an empty override flag with inherited days enables Save on Clear override', (tester) async {
      // Task opted out of inherited days (override flag set, no own days).
      final results = await openSheet(
        tester,
        inheritedDays: {1},
        isCurrentlyOverriding: true,
        sources: [(id: 10, name: 'Work', days: {1})],
      );

      expect(saveEnabled(tester), isFalse);
      await tester.tap(find.text('Clear override'));
      await tester.pump();
      expect(saveEnabled(tester), isTrue);
      await tapSave(tester);

      expect(results.single!.isOverride, isFalse);
    });
  });

  group('ScheduleDialog deadline editing', () {
    testWidgets('clearing a deadline saves the empty-string sentinel', (tester) async {
      final results = await openSheet(tester, currentDeadline: '2026-03-25');

      await tester.tap(find.byIcon(Icons.close));
      await tester.pump();
      expect(find.text('Set deadline'), findsOneWidget);
      await tapSave(tester);

      expect(results.single!.deadline, '');
    });

    testWidgets('type chip switches "Due by" to "On" and Save returns only the type', (tester) async {
      final results = await openSheet(tester, currentDeadline: '2026-03-25');

      await tester.tap(find.byIcon(Icons.swap_horiz));
      await tester.pump();

      expect(find.text('On: Mar 25, 2026'), findsOneWidget);
      expect(find.text('On'), findsOneWidget, reason: 'chip label');
      await tapSave(tester);

      final r = results.single!;
      expect(r.deadline, isNull, reason: 'date unchanged');
      expect(r.deadlineType, 'on');
    });

    testWidgets('type chip switches "On" back to "Due by"', (tester) async {
      final results = await openSheet(
        tester,
        currentDeadline: '2026-03-25',
        currentDeadlineType: 'on',
      );

      expect(find.text('On: Mar 25, 2026'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.swap_horiz));
      await tester.pump();
      expect(find.text('Due by: Mar 25, 2026'), findsOneWidget);
      await tapSave(tester);

      expect(results.single!.deadlineType, 'due_by');
    });

    testWidgets('toggling the type twice leaves Save disabled', (tester) async {
      await openSheet(tester, currentDeadline: '2026-03-25');

      await tester.tap(find.byIcon(Icons.swap_horiz));
      await tester.pump();
      expect(saveEnabled(tester), isTrue);
      await tester.tap(find.byIcon(Icons.swap_horiz));
      await tester.pump();
      expect(saveEnabled(tester), isFalse);
    });

    testWidgets('no type chip without a deadline', (tester) async {
      await openSheet(tester);
      expect(find.byIcon(Icons.swap_horiz), findsNothing);
    });
  });

  group('ScheduleDialog calendar picker', () {
    testWidgets('picking a day sets the deadline and Save returns it', (tester) async {
      final target = fifteenthOfNextMonth();
      final results = await openSheet(tester);

      await tester.tap(find.text('Set deadline'));
      await tester.pumpAndSettle();
      expect(find.text('Select date'), findsOneWidget);

      await tester.tap(inCalendar(find.byIcon(Icons.chevron_right)));
      await tester.pumpAndSettle();
      await tester.tap(inCalendar(find.text('15')));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'OK'));
      await tester.pumpAndSettle();

      expect(find.text('Select date'), findsNothing);
      expect(
        find.text('Due by: ${monthNames[target.month - 1]} 15, ${target.year}'),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.swap_horiz), findsOneWidget,
          reason: 'type chip appears once a date exists');
      await tapSave(tester);

      final r = results.single!;
      expect(r.deadline, ymd(target));
      expect(r.deadlineType, isNull, reason: 'type stays "due_by"');
    });

    testWidgets('a first pick resets the type to "Due by"', (tester) async {
      final target = fifteenthOfNextMonth();
      final results = await openSheet(tester, currentDeadlineType: 'on');

      await tester.tap(find.text('Set deadline'));
      await tester.pumpAndSettle();
      await tester.tap(inCalendar(find.byIcon(Icons.chevron_right)));
      await tester.pumpAndSettle();
      await tester.tap(inCalendar(find.text('15')));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'OK'));
      await tester.pumpAndSettle();

      expect(
        find.text('Due by: ${monthNames[target.month - 1]} 15, ${target.year}'),
        findsOneWidget,
      );
      await tapSave(tester);

      expect(results.single!.deadline, ymd(target));
      expect(results.single!.deadlineType, 'due_by');
    });

    testWidgets('OK without tapping a day picks today', (tester) async {
      final now = DateTime.now();
      final results = await openSheet(tester);

      await tester.tap(find.text('Set deadline'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'OK'));
      await tester.pumpAndSettle();
      await tapSave(tester);

      expect(results.single!.deadline, ymd(now));
    });

    testWidgets('re-picking keeps an existing "On" type', (tester) async {
      final target = fifteenthOfNextMonth();
      final results = await openSheet(
        tester,
        currentDeadline: ymd(DateTime.now()),
        currentDeadlineType: 'on',
      );

      await tester.tap(find.textContaining('On: '));
      await tester.pumpAndSettle();
      await tester.tap(inCalendar(find.byIcon(Icons.chevron_right)));
      await tester.pumpAndSettle();
      await tester.tap(inCalendar(find.text('15')));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'OK'));
      await tester.pumpAndSettle();
      await tapSave(tester);

      expect(results.single!.deadline, ymd(target));
      expect(results.single!.deadlineType, isNull, reason: 'still "on"');
    });

    testWidgets('opening on an existing future deadline and pressing OK is no change', (tester) async {
      final target = fifteenthOfNextMonth();
      await openSheet(tester, currentDeadline: ymd(target));

      await tester.tap(find.textContaining('Due by: '));
      await tester.pumpAndSettle();
      // Calendar opened on the existing date's month: "15" is selected there.
      expect(inCalendar(find.text('15')), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'OK'));
      await tester.pumpAndSettle();

      expect(saveEnabled(tester), isFalse);
    });

    testWidgets('a past deadline opens the calendar on today', (tester) async {
      final results = await openSheet(tester, currentDeadline: '2020-01-10');

      expect(find.text('Due by: Jan 10, 2020'), findsOneWidget);
      await tester.tap(find.text('Due by: Jan 10, 2020'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'OK'));
      await tester.pumpAndSettle();
      await tapSave(tester);

      expect(results.single!.deadline, ymd(DateTime.now()),
          reason: 'initial date is clamped to the first selectable day');
    });

    testWidgets('Cancel leaves the deadline unset', (tester) async {
      await openSheet(tester);

      await tester.tap(find.text('Set deadline'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('Select date'), findsNothing);
      expect(find.text('Set deadline'), findsOneWidget);
      expect(saveEnabled(tester), isFalse);
    });

    testWidgets('the close icon leaves the deadline unchanged', (tester) async {
      await openSheet(tester, currentDeadline: '2026-03-25');

      await tester.tap(find.text('Due by: Mar 25, 2026'));
      await tester.pumpAndSettle();
      await tester.tap(inCalendar(find.byIcon(Icons.close)));
      await tester.pumpAndSettle();

      expect(find.text('Select date'), findsNothing);
      expect(find.text('Due by: Mar 25, 2026'), findsOneWidget);
      expect(saveEnabled(tester), isFalse);
    });
  });
}
