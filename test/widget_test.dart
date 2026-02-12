import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:task_roulette/main.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  testWidgets('App renders', (WidgetTester tester) async {
    await tester.pumpWidget(const TaskRouletteApp());
    expect(find.text('Task Roulette'), findsOneWidget);
  });
}
