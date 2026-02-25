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

    testWidgets('shows "Random Pick" title and task name', (tester) async {
      await showRandomDialog(
        tester,
        task: Task(name: 'My Task'),
        hasChildren: false,
      );

      expect(find.text('Random Pick'), findsOneWidget);
      expect(find.text('My Task'), findsOneWidget);
    });

    testWidgets('shows Close and Go to Task buttons', (tester) async {
      await showRandomDialog(
        tester,
        task: Task(name: 'Test'),
        hasChildren: false,
      );

      expect(find.text('Close'), findsOneWidget);
      expect(find.text('Go to Task'), findsOneWidget);
    });

    testWidgets('does not show Go Deeper when hasChildren is false',
        (tester) async {
      await showRandomDialog(
        tester,
        task: Task(name: 'Leaf'),
        hasChildren: false,
      );

      expect(find.text('Go Deeper'), findsNothing);
    });

    testWidgets('shows Go Deeper when hasChildren is true', (tester) async {
      await showRandomDialog(
        tester,
        task: Task(name: 'Parent'),
        hasChildren: true,
      );

      expect(find.text('Go Deeper'), findsOneWidget);
    });

    testWidgets('Close returns null', (tester) async {
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

      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();

      expect(result, isNull);
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

      await tester.tap(find.text('Go Deeper'));
      await tester.pumpAndSettle();

      expect(result, RandomResultAction.goDeeper);
    });
  });

  group('RandomResultAction enum', () {
    test('has expected values', () {
      expect(RandomResultAction.values, containsAll([
        RandomResultAction.goDeeper,
        RandomResultAction.goToTask,
      ]));
    });
  });
}
