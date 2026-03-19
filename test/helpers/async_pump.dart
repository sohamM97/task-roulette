import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pumps the widget and waits for all async loading to complete.
/// DB operations inside widgets (via databaseFactoryFfiNoIsolate) need
/// runAsync to exit FakeAsync, then pump to process microtask continuations.
Future<void> pumpAndLoad(WidgetTester tester, Widget widget,
    {int rounds = 20}) async {
  await tester.pumpWidget(widget);
  await pumpAsync(tester, rounds: rounds);
}

/// Pumps async cycles without re-mounting the widget. Use after interactions
/// (longPress, tap) that trigger async work like DB queries or dialog loading.
Future<void> pumpAsync(WidgetTester tester, {int rounds = 20}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(
        () => Future.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
  }
}
