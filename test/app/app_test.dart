import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
    SharedPreferences.setMockInitialValues({});
    // Pre-initialize the database outside the fake async zone
    await tester.runAsync(() => DatabaseHelper().database);
    await tester.pumpWidget(const TaskRouletteApp());
    // Run async loading operations (SharedPreferences + DB queries)
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
    }
    // Bottom nav should show "Today" and "All Tasks" tabs
    expect(find.text('Today'), findsOneWidget);
    expect(find.text('All Tasks'), findsOneWidget);
    // With empty DB, Today's 5 shows the empty state
    expect(find.text('No tasks for today!'), findsOneWidget);
  });
}
