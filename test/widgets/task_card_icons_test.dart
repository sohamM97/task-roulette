import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:task_roulette/models/task.dart';
import 'package:task_roulette/widgets/task_card.dart';

void main() {
  group('TaskCard pin vs fire icon', () {
    Widget buildTaskCard({
      Task? task,
      bool isInTodaysFive = false,
      bool isPinnedInTodaysFive = false,
    }) {
      final t = task ??
          Task(
            id: 1,
            name: 'Test Task',
          );
      return MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 200,
            height: 200,
            child: TaskCard(
              task: t,
              onTap: () {},
              onDelete: () {},
              isInTodaysFive: isInTodaysFive,
              isPinnedInTodaysFive: isPinnedInTodaysFive,
            ),
          ),
        ),
      );
    }

    testWidgets('isInTodaysFive: true, isPinnedInTodaysFive: true '
        '-> shows push_pin icon', (tester) async {
      await tester.pumpWidget(buildTaskCard(
        isInTodaysFive: true,
        isPinnedInTodaysFive: true,
      ));

      expect(find.byIcon(Icons.push_pin), findsOneWidget);
      expect(find.byIcon(Icons.local_fire_department), findsNothing);
    });

    testWidgets('isInTodaysFive: true, isPinnedInTodaysFive: false '
        '-> shows local_fire_department icon', (tester) async {
      await tester.pumpWidget(buildTaskCard(
        isInTodaysFive: true,
        isPinnedInTodaysFive: false,
      ));

      expect(find.byIcon(Icons.local_fire_department), findsOneWidget);
      expect(find.byIcon(Icons.push_pin), findsNothing);
    });

    testWidgets('isInTodaysFive: false -> shows neither pin nor fire icon',
        (tester) async {
      await tester.pumpWidget(buildTaskCard(
        isInTodaysFive: false,
        isPinnedInTodaysFive: false,
      ));

      expect(find.byIcon(Icons.push_pin), findsNothing);
      expect(find.byIcon(Icons.local_fire_department), findsNothing);
    });

    testWidgets('isInTodaysFive: false, isPinnedInTodaysFive: true '
        '-> still shows neither (isInTodaysFive gates the icons)',
        (tester) async {
      // isPinnedInTodaysFive only matters when isInTodaysFive is true
      await tester.pumpWidget(buildTaskCard(
        isInTodaysFive: false,
        isPinnedInTodaysFive: true,
      ));

      expect(find.byIcon(Icons.push_pin), findsNothing);
      expect(find.byIcon(Icons.local_fire_department), findsNothing);
    });

    testWidgets('pin icon uses tertiary color', (tester) async {
      await tester.pumpWidget(buildTaskCard(
        isInTodaysFive: true,
        isPinnedInTodaysFive: true,
      ));

      final icon = tester.widget<Icon>(find.byIcon(Icons.push_pin));
      // The icon should use colorScheme.tertiary
      final context = tester.element(find.byType(TaskCard));
      final tertiary = Theme.of(context).colorScheme.tertiary;
      expect(icon.color, tertiary);
    });

    testWidgets('fire icon uses tertiary color', (tester) async {
      await tester.pumpWidget(buildTaskCard(
        isInTodaysFive: true,
        isPinnedInTodaysFive: false,
      ));

      final icon = tester.widget<Icon>(find.byIcon(Icons.local_fire_department));
      final context = tester.element(find.byType(TaskCard));
      final tertiary = Theme.of(context).colorScheme.tertiary;
      expect(icon.color, tertiary);
    });

    testWidgets('pin icon has size 16', (tester) async {
      await tester.pumpWidget(buildTaskCard(
        isInTodaysFive: true,
        isPinnedInTodaysFive: true,
      ));

      final icon = tester.widget<Icon>(find.byIcon(Icons.push_pin));
      expect(icon.size, 16);
    });

    testWidgets('high priority flag and pin icon can coexist', (tester) async {
      final hpTask = Task(
        id: 2,
        name: 'HP Pinned Task',
        priority: 1,
      );
      await tester.pumpWidget(buildTaskCard(
        task: hpTask,
        isInTodaysFive: true,
        isPinnedInTodaysFive: true,
      ));

      // Both icons present
      expect(find.byIcon(Icons.push_pin), findsOneWidget);
      expect(find.byIcon(Icons.flag), findsOneWidget);
    });
  });
}
