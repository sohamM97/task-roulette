import 'package:flutter_test/flutter_test.dart';
import 'package:task_roulette/main.dart';

void main() {
  testWidgets('App renders', (WidgetTester tester) async {
    await tester.pumpWidget(const TaskRouletteApp());
    expect(find.text('TaskRoulette'), findsOneWidget);
  });
}
