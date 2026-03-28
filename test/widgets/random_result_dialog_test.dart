import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:task_roulette/models/task.dart';
import 'package:task_roulette/widgets/random_result_dialog.dart';

void main() {
  group('RandomResultDialog', () {
    Future<RandomResultAction?> showRandomDialog(
      WidgetTester tester, {
      required Task task,
      required bool hasChildren,
      bool canPickAnother = true,
    }) async {
      RandomResultAction? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  result = await showDialog<RandomResultAction>(
                    context: context,
                    builder: (_) => RandomResultDialog(
                      task: task,
                      hasChildren: hasChildren,
                      canPickAnother: canPickAnother,
                    ),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      return result;
    }

    testWidgets('shows title and task name', (tester) async {
      await showRandomDialog(
        tester,
        task: Task(name: 'My Task'),
        hasChildren: false,
      );

      expect(find.text('Lucky Pick'), findsOneWidget);
      expect(find.text('My Task'), findsOneWidget);
    });

    testWidgets('shows Go to Task button', (tester) async {
      await showRandomDialog(
        tester,
        task: Task(name: 'Test'),
        hasChildren: false,
      );

      expect(find.text('Go to Task'), findsOneWidget);
    });

    testWidgets('does not show Go Deeper when hasChildren is false',
        (tester) async {
      await showRandomDialog(
        tester,
        task: Task(name: 'Leaf'),
        hasChildren: false,
      );

      expect(find.byTooltip('Go Deeper'), findsNothing);
    });

    testWidgets('shows Go Deeper when hasChildren is true', (tester) async {
      await showRandomDialog(
        tester,
        task: Task(name: 'Parent'),
        hasChildren: true,
      );

      expect(find.byTooltip('Go Deeper'), findsOneWidget);
    });

    testWidgets('Go to Task returns goToTask', (tester) async {
      RandomResultAction? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  result = await showDialog<RandomResultAction>(
                    context: context,
                    builder: (_) => RandomResultDialog(
                      task: Task(name: 'Test'),
                      hasChildren: false,
                    ),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Go to Task'));
      await tester.pumpAndSettle();

      expect(result, RandomResultAction.goToTask);
    });

    testWidgets('shows Spin Again by default', (tester) async {
      await showRandomDialog(
        tester,
        task: Task(name: 'Test'),
        hasChildren: false,
      );

      expect(find.byTooltip('Spin Again'), findsOneWidget);
    });

    testWidgets('hides Spin Again when canPickAnother is false',
        (tester) async {
      await showRandomDialog(
        tester,
        task: Task(name: 'Test'),
        hasChildren: false,
        canPickAnother: false,
      );

      expect(find.byTooltip('Spin Again'), findsNothing);
    });

    testWidgets('Spin Again returns pickAnother', (tester) async {
      RandomResultAction? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  result = await showDialog<RandomResultAction>(
                    context: context,
                    builder: (_) => RandomResultDialog(
                      task: Task(name: 'Test'),
                      hasChildren: false,
                    ),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Spin Again'));
      await tester.pumpAndSettle();

      expect(result, RandomResultAction.pickAnother);
    });

    testWidgets('Go Deeper returns goDeeper', (tester) async {
      RandomResultAction? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  result = await showDialog<RandomResultAction>(
                    context: context,
                    builder: (_) => RandomResultDialog(
                      task: Task(name: 'Parent'),
                      hasChildren: true,
                    ),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Go Deeper'));
      await tester.pumpAndSettle();

      expect(result, RandomResultAction.goDeeper);
    });

    testWidgets('tap outside dismisses dialog', (tester) async {
      await showRandomDialog(
        tester,
        task: Task(name: 'Test'),
        hasChildren: false,
      );

      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      expect(find.text('Lucky Pick'), findsNothing);
    });
  });

  group('RandomResultAction enum', () {
    test('has expected values', () {
      expect(RandomResultAction.values, containsAll([
        RandomResultAction.goDeeper,
        RandomResultAction.goToTask,
        RandomResultAction.pickAnother,
      ]));
    });
  });
}
