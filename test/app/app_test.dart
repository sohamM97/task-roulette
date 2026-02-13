import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:task_roulette/data/database_helper.dart';
import 'package:task_roulette/main.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    DatabaseHelper.testDatabasePath = inMemoryDatabasePath;
  });

  testWidgets('App renders', (WidgetTester tester) async {
    await tester.pumpWidget(const TaskRouletteApp());
    expect(find.text('Task Roulette'), findsOneWidget);
  });
}
