import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:task_roulette/data/database_helper.dart';
import 'package:task_roulette/main.dart';

import '../helpers/async_pump.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    DatabaseHelper.testDatabasePath = inMemoryDatabasePath;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final db = DatabaseHelper();
    await db.reset();
  });

  /// Pumps the app and waits for async initialization. Mirrors the original
  /// app_test.dart pattern but uses the shared `pumpAsync` helper.
  Future<void> pumpApp(WidgetTester tester) async {
    await tester.runAsync(() => DatabaseHelper().database);
    await tester.pumpWidget(const TaskRouletteApp());
    await pumpAsync(tester, rounds: 20);
  }

  /// Returns the order of NavigationDestination labels found in the bottom
  /// nav bar by walking the NavigationBar's destinations list.
  List<String> bottomNavLabels(WidgetTester tester) {
    final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
    return bar.destinations
        .whereType<NavigationDestination>()
        .map((d) => d.label)
        .toList();
  }

  group('AppShell bottom nav', () {
    // Baseline — confirms the app boots and all three tabs are present in
    // the bottom NavigationBar. (Scoped to the NavigationBar because
    // "Starred" also appears as the AppBar title of the StarredScreen.)
    testWidgets('renders all three bottom-nav tabs', (tester) async {
      await pumpApp(tester);

      final inBar = find.descendant(
        of: find.byType(NavigationBar),
        matching: find.byType(Text),
      );
      final labels = tester
          .widgetList<Text>(inBar)
          .map((t) => t.data)
          .where((s) => s != null)
          .toSet();
      expect(labels.contains('Starred'), isTrue);
      expect(labels.contains('Today'), isTrue);
      expect(labels.contains('All Tasks'), isTrue);
    });

    // Regression — the reorder put Starred at index 0; if a future change
    // shuffles the destinations or constants without updating the build()
    // order, this catches it.
    testWidgets('destinations are in Starred, Today, All Tasks order',
        (tester) async {
      await pumpApp(tester);

      expect(
        bottomNavLabels(tester),
        equals(<String>['Starred', 'Today', 'All Tasks']),
      );
    });

    // Mechanism — the new _defaultTab = _tabStarred constant must wire
    // through to NavigationBar.selectedIndex on first frame.
    testWidgets('Starred tab is selected by default on launch',
        (tester) async {
      await pumpApp(tester);

      final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(bar.selectedIndex, 0,
          reason: 'Starred tab (index 0) should be the default landing tab.');
    });

    // Regression — with empty DB, the *visible* screen on launch must be the
    // Starred screen's empty state, not Today's 5. This is the exact
    // assertion that failed when the tab order was flipped — proof that the
    // default landing tab actually swapped.
    testWidgets(
        'shows Starred empty state on launch with empty DB '
        '(not Today\'s 5 empty state)', (tester) async {
      await pumpApp(tester);

      expect(find.text('No starred tasks yet'), findsOneWidget);
      expect(find.text('No tasks for today!'), findsNothing);
    });

    /// Invokes the NavigationBar's onDestinationSelected callback directly
    /// for a given index. Tapping the NavigationDestination through
    /// hit-testing is flaky under FakeAsync (the InkWell + ripple need
    /// real-time pumping). Invoking the callback exercises the exact same
    /// code path — animateToPage(index, ...) — without that fragility.
    ///
    /// We then advance the PageController animation by pumping with an
    /// explicit duration (animation runs for 300ms), then run async rounds
    /// to drain any onPageChanged DB-load side-effects.
    Future<void> selectDestination(WidgetTester tester, int index) async {
      final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
      bar.onDestinationSelected!(index);
      // Advance the 300ms animation in 50ms steps so onPageChanged fires.
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      // Drain post-page-change async work (DB loads in newly built screens).
      await pumpAsync(tester, rounds: 20);
    }

    // Mechanism — selecting the Today destination (now index 1) must
    // animate the PageView to page 1 and update selectedIndex. Verifies the
    // named-constant rewrite of animateToPage — guards against a regression
    // where the destinations list order is changed without updating
    // _tabToday.
    testWidgets('selecting Today destination animates PageView to index 1',
        (tester) async {
      await pumpApp(tester);

      await selectDestination(tester, 1);

      final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(bar.selectedIndex, 1,
          reason: 'Today destination is at index 1 in the new order.');

      final pageView = tester.widget<PageView>(find.byType(PageView));
      expect(pageView.controller!.page, closeTo(1.0, 0.01));
    });

    // Mechanism — selecting All Tasks (index 2) animates to the third
    // page. Guards against _tabAllTasks drifting from the
    // children/destinations list order.
    testWidgets('selecting All Tasks destination animates PageView to index 2',
        (tester) async {
      await pumpApp(tester);

      await selectDestination(tester, 2);

      final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(bar.selectedIndex, 2);
      final pageView = tester.widget<PageView>(find.byType(PageView));
      expect(pageView.controller!.page, closeTo(2.0, 0.01));
    });

    // Edge case — after navigating to Today, selecting Starred (index 0)
    // again must return there. Catches a scenario where a stale hard-coded
    // index in animateToPage would misroute the navigation.
    testWidgets('tab switching round-trips: Starred -> Today -> Starred',
        (tester) async {
      await pumpApp(tester);

      // Start on Starred (default), switch to Today.
      await selectDestination(tester, 1);
      {
        final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
        expect(bar.selectedIndex, 1);
      }

      // Switch back to Starred.
      await selectDestination(tester, 0);

      final bar = tester.widget<NavigationBar>(find.byType(NavigationBar));
      expect(bar.selectedIndex, 0);
      final pageView = tester.widget<PageView>(find.byType(PageView));
      expect(pageView.controller!.page, closeTo(0.0, 0.01));
    });

    // Regression — destinations use star/star_outline at index 0 and
    // today/today_outlined at index 1. If the order of destinations is
    // accidentally reverted without flipping the icons, this catches it
    // because the *selected* destination (Starred) renders the filled
    // selectedIcon.
    testWidgets('selected destination icon is Icons.star (filled) on launch',
        (tester) async {
      await pumpApp(tester);

      // Filled star icon is shown for the selected Starred tab.
      expect(find.byIcon(Icons.star), findsOneWidget);
      // Outlined today icon is shown for the unselected Today tab.
      expect(find.byIcon(Icons.today_outlined), findsOneWidget);
      // The unselected variants for Starred + the filled today must NOT
      // both appear (would imply wrong tab is selected).
      expect(find.byIcon(Icons.star_outline), findsNothing);
      expect(find.byIcon(Icons.today), findsNothing);
    });
  });
}
