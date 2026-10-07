import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../helpers/async_pump.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:task_roulette/data/database_helper.dart';
import 'package:task_roulette/models/task.dart';
import 'package:task_roulette/providers/auth_provider.dart';
import 'package:task_roulette/providers/task_provider.dart';
import 'package:task_roulette/providers/theme_provider.dart';
import 'package:task_roulette/screens/task_list_screen.dart';
import 'package:task_roulette/services/sync_service.dart';
import 'package:task_roulette/utils/display_utils.dart';
import 'package:task_roulette/widgets/delete_task_dialog.dart';
import 'package:task_roulette/widgets/spotlight_overlay.dart';
import 'package:task_roulette/widgets/task_card.dart';
import 'package:task_roulette/widgets/task_picker_dialog.dart';
import 'package:task_roulette/widgets/triage_dialog.dart';

void main() {
  late DatabaseHelper db;
  late TaskProvider provider;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    DatabaseHelper.testDatabasePath = inMemoryDatabasePath;
  });

  setUp(() async {
    db = DatabaseHelper();
    await db.reset();
    await db.database;
    provider = TaskProvider();
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    await db.reset();
  });

  Widget buildTestWidget() {
    final authProvider = AuthProvider();
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: provider),
        ChangeNotifierProvider(create: (_) => ThemeProvider()),
        ChangeNotifierProvider.value(value: authProvider),
        Provider<SyncService>(
          create: (_) => SyncService(authProvider),
          dispose: (_, sync) => sync.dispose(),
        ),
      ],
      child: const MaterialApp(
        home: TaskListScreen(),
      ),
    );
  }

  /// Pumps the screen in an 800x2000 window. The card long-press sheet lists
  /// up to nine actions; at the default 800x600 the lower ones sit outside
  /// the sheet's visible area and taps on them miss.
  Future<void> pumpTall(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await pumpAndLoad(tester, buildTestWidget());
  }

  /// Advances the fake clock (sheet, dialog and snackbar animations) and lets
  /// the real database work run. Unlike pumpAndSettle it does not hang while
  /// the search-pool spinner is up.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 300));
      await pumpAsync(tester, rounds: 8);
    }
  }

  /// Long-presses the card named [name] and taps [action] in its sheet.
  Future<void> cardAction(
      WidgetTester tester, String name, String action) async {
    await tester.longPress(find.text(name));
    await tester.pumpAndSettle();
    await tester.tap(find.text(action));
    await settle(tester);
  }

  /// Opens the app bar's overflow menu and taps [item].
  Future<void> overflowAction(WidgetTester tester, String item) async {
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text(item));
    await settle(tester);
  }

  /// Taps the row named [name] inside the open [TaskPickerDialog].
  Future<void> pickInPicker(WidgetTester tester, String name) async {
    await tester.tap(find.descendant(
        of: find.byType(TaskPickerDialog), matching: find.text(name)));
    await settle(tester);
  }

  /// The [TaskCard] in the grid that shows [name].
  TaskCard cardFor(WidgetTester tester, String name) => tester.widget<TaskCard>(
      find.ancestor(of: find.text(name), matching: find.byType(TaskCard)));

  Future<void> tapUndo(WidgetTester tester) async {
    await tester.tap(find.text('Undo'));
    await settle(tester);
  }

  group('TaskListScreen root state', () {
    testWidgets('shows "Task Roulette" title at root', (tester) async {
      await tester.runAsync(() async {
        await provider.loadRootTasks();
      });
      await pumpAndLoad(tester, buildTestWidget());

      expect(find.text('Task Roulette'), findsOneWidget);
    });

    testWidgets('shows empty state when no tasks at root', (tester) async {
      await tester.runAsync(() async {
        await provider.loadRootTasks();
      });
      await pumpAndLoad(tester, buildTestWidget());

      // EmptyState widget shows "No tasks yet"
      expect(find.textContaining('No tasks yet'), findsOneWidget);
    });

    testWidgets('shows add FAB at root', (tester) async {
      await tester.runAsync(() async {
        await provider.loadRootTasks();
      });
      await pumpAndLoad(tester, buildTestWidget());

      expect(find.byIcon(Icons.add), findsOneWidget);
    });

    testWidgets('does not show link FAB at root', (tester) async {
      await tester.runAsync(() async {
        await provider.loadRootTasks();
      });
      await pumpAndLoad(tester, buildTestWidget());

      expect(find.byIcon(Icons.playlist_add), findsNothing);
    });

    testWidgets('shows back button hidden at root', (tester) async {
      await tester.runAsync(() async {
        await provider.loadRootTasks();
      });
      await pumpAndLoad(tester, buildTestWidget());

      expect(find.byIcon(Icons.arrow_back), findsNothing);
    });

    testWidgets('shows task graph button at root', (tester) async {
      await tester.runAsync(() async {
        await provider.loadRootTasks();
      });
      await pumpAndLoad(tester, buildTestWidget());

      expect(find.byIcon(Icons.account_tree_outlined), findsOneWidget);
    });

    testWidgets('shows task cards in grid when tasks exist', (tester) async {
      await tester.runAsync(() async {
        await db.insertTask(Task(name: 'Work'));
        await db.insertTask(Task(name: 'Personal'));
        await provider.loadRootTasks();
      });
      await pumpAndLoad(tester, buildTestWidget());

      expect(find.text('Work'), findsOneWidget);
      expect(find.text('Personal'), findsOneWidget);
    });

    testWidgets('shows flare FAB when tasks exist', (tester) async {
      await tester.runAsync(() async {
        await db.insertTask(Task(name: 'Task'));
        await provider.loadRootTasks();
      });
      await pumpAndLoad(tester, buildTestWidget());

      expect(find.byIcon(Icons.flare), findsOneWidget);
    });

    testWidgets('hides flare FAB when no tasks', (tester) async {
      await tester.runAsync(() async {
        await provider.loadRootTasks();
      });
      await pumpAndLoad(tester, buildTestWidget());

      expect(find.byIcon(Icons.flare), findsNothing);
    });

    testWidgets('no star button at root', (tester) async {
      await tester.runAsync(() async {
        await provider.loadRootTasks();
      });
      await pumpAndLoad(tester, buildTestWidget());

      expect(find.byIcon(Icons.star_outline), findsNothing);
      expect(find.byIcon(Icons.star), findsNothing);
    });
  });

  group('TaskListScreen navigation', () {
    testWidgets('navigating into a task shows its name in AppBar',
        (tester) async {
      await tester.runAsync(() async {
        final parentId = await db.insertTask(Task(name: 'My Project'));
        final childId = await db.insertTask(Task(name: 'Sub Task'));
        await db.addRelationship(parentId, childId);
        await provider.loadRootTasks();
      });
      await pumpAndLoad(tester, buildTestWidget());

      // Tap on the task card to navigate
      await tester.tap(find.text('My Project'));
      await pumpAsync(tester);

      expect(find.text('My Project'), findsWidgets); // AppBar + breadcrumb
      expect(find.text('Sub Task'), findsOneWidget);
    });

    testWidgets('shows back button when navigated into task', (tester) async {
      await tester.runAsync(() async {
        final parentId = await db.insertTask(Task(name: 'Parent'));
        final childId = await db.insertTask(Task(name: 'Child'));
        await db.addRelationship(parentId, childId);
        await provider.loadRootTasks();
      });
      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('Parent'));
      await pumpAsync(tester);

      expect(find.byIcon(Icons.arrow_back), findsOneWidget);
    });

    testWidgets('back button returns to root', (tester) async {
      await tester.runAsync(() async {
        final parentId = await db.insertTask(Task(name: 'Parent'));
        final childId = await db.insertTask(Task(name: 'Child'));
        await db.addRelationship(parentId, childId);
        await provider.loadRootTasks();
      });
      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('Parent'));
      await pumpAsync(tester);

      await tester.tap(find.byIcon(Icons.arrow_back));
      await pumpAsync(tester);

      expect(find.text('Task Roulette'), findsOneWidget);
    });

    testWidgets('shows breadcrumb when navigated into task', (tester) async {
      await tester.runAsync(() async {
        final parentId = await db.insertTask(Task(name: 'Level 1'));
        final childId = await db.insertTask(Task(name: 'Level 2'));
        await db.addRelationship(parentId, childId);
        await provider.loadRootTasks();
      });
      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('Level 1'));
      await pumpAsync(tester);

      // Breadcrumb should show "Task Roulette" as clickable root + current task
      expect(find.text('Task Roulette'), findsOneWidget); // breadcrumb root
      // Chevron separator
      expect(find.byIcon(Icons.chevron_right), findsWidgets);
    });

    testWidgets('hides task graph button when not at root', (tester) async {
      await tester.runAsync(() async {
        final parentId = await db.insertTask(Task(name: 'Parent'));
        final childId = await db.insertTask(Task(name: 'Child'));
        await db.addRelationship(parentId, childId);
        await provider.loadRootTasks();
      });
      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('Parent'));
      await pumpAsync(tester);

      expect(find.byIcon(Icons.account_tree_outlined), findsNothing);
    });

    testWidgets('shows link FAB when not at root', (tester) async {
      await tester.runAsync(() async {
        final parentId = await db.insertTask(Task(name: 'Parent'));
        final childId = await db.insertTask(Task(name: 'Child'));
        await db.addRelationship(parentId, childId);
        await provider.loadRootTasks();
      });
      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('Parent'));
      await pumpAsync(tester);

      expect(find.byIcon(Icons.playlist_add), findsOneWidget);
    });

    testWidgets('shows star button when navigated into task', (tester) async {
      await tester.runAsync(() async {
        final parentId = await db.insertTask(Task(name: 'Parent'));
        final childId = await db.insertTask(Task(name: 'Child'));
        await db.addRelationship(parentId, childId);
        await provider.loadRootTasks();
      });
      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('Parent'));
      await pumpAsync(tester);

      expect(find.byIcon(Icons.star_outline), findsOneWidget);
    });
  });

  group('TaskListScreen leaf detail', () {
    testWidgets('shows leaf task detail when navigating into a leaf',
        (tester) async {
      await tester.runAsync(() async {
        final parentId = await db.insertTask(Task(name: 'Parent'));
        final childId = await db.insertTask(Task(name: 'Leaf Task'));
        await db.addRelationship(parentId, childId);
        await provider.loadRootTasks();
      });
      await pumpAndLoad(tester, buildTestWidget());

      // Navigate into parent, then into leaf
      await tester.tap(find.text('Parent'));
      await pumpAsync(tester);
      await tester.tap(find.text('Leaf Task'));
      await pumpAsync(tester);

      // Should show the leaf task name in AppBar
      expect(find.text('Leaf Task'), findsWidgets);
    });

    /// Taps [label] and lets both the fake clock and the real database work run
    /// on. The completion animation holds for 700ms before the write, and a
    /// bare pump never moves the clock under FakeAsync.
    Future<void> tapAndSettle(WidgetTester tester, String label) async {
      await tester.tap(find.text(label));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 300));
        await pumpAsync(tester, rounds: 5);
      }
    }

    /// Drills into "Parent" > "Leaf Task" and returns the leaf's id.
    Future<int> openLeafDetail(WidgetTester tester) async {
      late int childId;
      await tester.runAsync(() async {
        final parentId = await db.insertTask(Task(name: 'Parent'));
        childId = await db.insertTask(Task(name: 'Leaf Task'));
        await db.addRelationship(parentId, childId);
        final sibling = await db.insertTask(Task(name: 'Sibling'));
        await db.addRelationship(parentId, sibling);
        await provider.loadRootTasks();
      });
      await pumpAndLoad(tester, buildTestWidget());
      await tester.tap(find.text('Parent'));
      await pumpAsync(tester);
      await tester.tap(find.text('Leaf Task'));
      await pumpAsync(tester);
      return childId;
    }

    // [Baseline] The leaf detail's "Done today" runs through the shared
    // markTaskDoneToday with navigateBack, so it both stamps last_worked_at and
    // pops back to the parent list — landing back on the sibling list is the
    // half a caller that only mutates would lose.
    testWidgets('"Done today" marks the leaf and pops back to the parent',
        (tester) async {
      final leafId = await openLeafDetail(tester);

      await tapAndSettle(tester, 'Done today');

      final task = await tester.runAsync(() => db.getTaskById(leafId));
      expect(task!.isWorkedOnToday, isTrue);
      expect(task.completedAt, isNull);
      // Back on the parent's child list, not the leaf detail.
      expect(find.text('Sibling'), findsOneWidget);
      expect(find.text('Done today'), findsNothing);
    });

    // [Baseline] "Done for good!" runs through the shared completeTaskForGood
    // with navigateBack: the task is completed and the stack pops, so the
    // archived task is no longer listed.
    testWidgets('"Done for good!" completes the leaf and pops back',
        (tester) async {
      final leafId = await openLeafDetail(tester);

      await tapAndSettle(tester, 'Done for good!');

      final task = await tester.runAsync(() => db.getTaskById(leafId));
      expect(task!.completedAt, isNotNull);
      expect(find.text('Sibling'), findsOneWidget);
      expect(find.text('Leaf Task'), findsNothing);
    });
  });

  group('TaskListScreen inbox', () {
    testWidgets('shows inbox section at root when inbox tasks exist',
        (tester) async {
      await tester.runAsync(() async {
        await db.insertTask(Task(name: 'Regular task'));
        await db.insertTask(Task(name: 'Inbox task', isInbox: true));
        await provider.loadRootTasks();
      });
      await pumpAndLoad(tester, buildTestWidget());

      // Should show both tasks
      expect(find.text('Regular task'), findsOneWidget);
      expect(find.text('Inbox task'), findsOneWidget);
      // Inbox section header
      expect(find.textContaining('Inbox'), findsWidgets);
    });
  });

  group('TaskListScreen link button', () {
    testWidgets('shows link icon when task has URL and children',
        (tester) async {
      await tester.runAsync(() async {
        final parentId = await db.insertTask(
            Task(name: 'Linked', url: 'https://example.com'));
        final childId = await db.insertTask(Task(name: 'Child'));
        await db.addRelationship(parentId, childId);
        await provider.loadRootTasks();
      });
      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('Linked'));
      await pumpAsync(tester);

      expect(find.byIcon(Icons.link), findsOneWidget);
    });

    testWidgets('hides link icon when task has no URL', (tester) async {
      await tester.runAsync(() async {
        final parentId = await db.insertTask(Task(name: 'No URL'));
        final childId = await db.insertTask(Task(name: 'Child'));
        await db.addRelationship(parentId, childId);
        await provider.loadRootTasks();
      });
      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('No URL'));
      await pumpAsync(tester);

      expect(find.byIcon(Icons.link), findsNothing);
    });
  });

  group('Pin-for-today on add (empty-day regression)', () {
    // [Regression] Bug: AddTaskFlow._pinNewTask returned true (reporting
    // success) without pinning when no Today's 5 row existed yet. Since Today's
    // 5 is empty-by-default each day, "Pin for today" on a fresh day silently
    // created the task UNPINNED. After the fix it bootstraps an empty state and
    // pins into it.
    testWidgets('pinning a new task on an empty day actually pins it',
        (tester) async {
      await tester.runAsync(() => provider.loadRootTasks());
      await pumpAndLoad(tester, buildTestWidget());

      // Empty day — no saved Today's 5 state.
      final before = await tester
          .runAsync(() => db.loadTodaysFiveState(todayDateKey()));
      expect(before, isNull);

      // Open the Add dialog via the + FAB, turn Pin ON, add a task.
      await tester.tap(find.byIcon(Icons.add));
      await pumpAsync(tester);
      await tester.tap(find.text('Pin'));
      await pumpAsync(tester);
      await tester.enterText(find.byType(TextField).first, 'Focus task');
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      });
      await pumpAsync(tester);

      // The task is pinned into a freshly bootstrapped Today's 5 state.
      final after = await tester
          .runAsync(() => db.loadTodaysFiveState(todayDateKey()));
      expect(after, isNotNull);
      expect(after!.pinnedIds, isNotEmpty);
      expect(after.taskIds.length, 1);
    });
  });

  group('Deadline-today suppression from All Tasks unpin (Codex P2)', () {
    // [Regression] Codex P2: unpinning a due-today task from All Tasks only
    // dropped it from todays_five_state without writing a suppression, so the
    // next Today reconcile re-auto-pinned it (the unpin didn't stick). The
    // unpin must now record the suppression, matching the Today screen's remove.
    testWidgets('unpinning a due-today task from All Tasks suppresses it',
        (tester) async {
      late int id;
      await tester.runAsync(() async {
        id = await db.insertTask(
            Task(name: 'Due today leaf', deadline: todayDateKey()));
        await db.saveTodaysFiveState(
          date: todayDateKey(),
          taskIds: [id],
          completedIds: const {},
          workedOnIds: const {},
          pinnedIds: {id},
        );
        await provider.loadRootTasks();
      });

      await pumpAndLoad(tester, buildTestWidget());

      // Navigate into the leaf to reach its detail view + pin toggle.
      await tester.tap(find.text('Due today leaf'));
      await pumpAsync(tester);

      // Unpin from All Tasks (PinButton shows tooltip 'Unpin' when pinned).
      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('Unpin'));
      });
      await pumpAsync(tester);

      // Dropped from Today's 5 AND recorded as suppressed.
      final saved =
          await tester.runAsync(() => db.loadTodaysFiveState(todayDateKey()));
      expect(saved?.taskIds ?? const <int>[], isNot(contains(id)));
      final suppressed = await tester
          .runAsync(() => db.getDeadlineSuppressedIds(todayDateKey()));
      expect(suppressed, contains(id));
    });

    // [Regression] Codex P2 (round 2): the suppression was gated to due-today
    // tasks only, so unpinning a NON-deadline pinned task left no tombstone and
    // the removal bounced back (re-added by the local-only-pinned merge append
    // on the next pull). It must now suppress regardless of deadline.
    testWidgets('unpinning a non-deadline task from All Tasks suppresses it',
        (tester) async {
      late int id;
      await tester.runAsync(() async {
        id = await db.insertTask(Task(name: 'Plain pinned leaf'));
        await db.saveTodaysFiveState(
          date: todayDateKey(),
          taskIds: [id],
          completedIds: const {},
          workedOnIds: const {},
          pinnedIds: {id},
        );
        await provider.loadRootTasks();
      });

      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('Plain pinned leaf'));
      await pumpAsync(tester);

      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('Unpin'));
      });
      await pumpAsync(tester);

      final saved =
          await tester.runAsync(() => db.loadTodaysFiveState(todayDateKey()));
      expect(saved?.taskIds ?? const <int>[], isNot(contains(id)));
      final suppressed = await tester
          .runAsync(() => db.getDeadlineSuppressedIds(todayDateKey()));
      expect(suppressed, contains(id));
    });
  });

  group('Add via + FAB nesting (_runAddFlow refactor)', () {
    // [Regression] The "+" FAB add was extracted into _runAddFlow(atRoot: false)
    // when create-from-search (atRoot: true) was unified into the same helper.
    // atRoot: false must keep filing under the currently drilled-in parent
    // (parentId = currentParent.id). If the refactor had wired the FAB to
    // atRoot: true (as create-from-search does), a subtask added while drilled
    // into a parent would wrongly land at the root instead of under the parent.
    testWidgets('+ FAB while drilled into a parent nests the task under it',
        (tester) async {
      late int parentId;
      await tester.runAsync(() async {
        parentId = await db.insertTask(Task(name: 'My Project'));
        final childId = await db.insertTask(Task(name: 'Existing sub'));
        await db.addRelationship(parentId, childId);
        await provider.loadRootTasks();
      });
      await pumpAndLoad(tester, buildTestWidget());

      // Drill into the parent, then add via the + FAB.
      await tester.tap(find.text('My Project'));
      await pumpAsync(tester);

      await tester.tap(find.byIcon(Icons.add));
      await pumpAsync(tester);
      await tester.enterText(find.byType(TextField).first, 'New sub');
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      });
      await pumpAsync(tester);

      // The new task is a child of the drilled-in parent, NOT a root task.
      final children =
          await tester.runAsync(() => db.getChildren(parentId)) ?? [];
      expect(children.map((t) => t.name), contains('New sub'));
      final roots = await tester.runAsync(() => db.getRootTasks()) ?? [];
      expect(roots.map((t) => t.name), isNot(contains('New sub')));
    });

    // [Baseline] atRoot: false at the root level (not drilled in) still files at
    // root — currentParent is null so parentId resolves to null either way. This
    // pins the "no parent → root" leg of the same branch so a future change to
    // the atRoot ternary can't silently break root adds.
    testWidgets('+ FAB at root files the task at root', (tester) async {
      await tester.runAsync(() => provider.loadRootTasks());
      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.byIcon(Icons.add));
      await pumpAsync(tester);
      await tester.enterText(find.byType(TextField).first, 'Root task');
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      });
      await pumpAsync(tester);

      final roots = await tester.runAsync(() => db.getRootTasks()) ?? [];
      expect(roots.map((t) => t.name), contains('Root task'));
    });
  });

  group('"already exists" suggestion → per-surface action (_runAddFlow)', () {
    // The + FAB seeds AddTaskFlow with existingTasks, so typing a name that
    // matches an existing task surfaces the inline suggestion. The action verb
    // and onUseExisting behaviour differ by whether we're at root (Open) or
    // drilled into a parent (Add here / link).

    // Opens the + FAB add dialog, types [name], opens the in-field "did you
    // mean" popup (info_outline indicator), then selects the match row. The
    // action label is carried as the icon's tooltip (not visible text), so the
    // row is located via byTooltip — unique to the suggestion popup.
    Future<void> tapSuggestion(
        WidgetTester tester, String name, String label) async {
      await tester.tap(find.byIcon(Icons.add));
      await pumpAsync(tester);
      await tester.enterText(find.byType(TextField).first, name);
      await pumpAsync(tester);
      // Open the popup and settle its open animation (pumpAsync advances no fake
      // time, leaving the menu collapsed at the anchor and unhittable), then
      // select the (single) enabled match item. Targeting the PopupMenuItem
      // avoids ambiguity with the drill-in view's own action icons (e.g. the
      // "Add here" add_link icon also appears as a screen button). [label] is
      // kept for call-site readability of which surface action is exercised.
      await tester.tap(find.byIcon(Icons.info_outline));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.byWidgetPredicate(
            (w) => w is PopupMenuItem<Task> && w.enabled));
      });
      await pumpAsync(tester);
    }

    // [Mechanism] At ROOT there's no parent to file under, so the action is
    // "Open" → provider.navigateToTask(existing). The existing task is opened
    // (becomes currentParent) and no duplicate is created.
    testWidgets('root: Open navigates to the existing task, no duplicate',
        (tester) async {
      late int existingId;
      await tester.runAsync(() async {
        existingId = await db.insertTask(Task(name: 'Write report'));
        await provider.loadRootTasks();
      });
      await pumpAndLoad(tester, buildTestWidget());

      await tapSuggestion(tester, 'write REPORT', 'Open');

      expect(provider.currentParent?.id, existingId,
          reason: 'Open navigates into the existing task');
      final all = await tester.runAsync(() => db.getAllTasks());
      expect(all!.where((t) => t.name == 'Write report'), hasLength(1),
          reason: 'no duplicate created');
    });

    // [Mechanism] Drilled into a parent the action is "Add here" →
    // addParentToTask(existing, parent): the existing task is linked as a child
    // of the current parent (multi-parent DAG) instead of being re-created.
    testWidgets('under a parent: Add here links the existing task as a child',
        (tester) async {
      late int parentId;
      late int existingId;
      await tester.runAsync(() async {
        parentId = await db.insertTask(Task(name: 'My Project'));
        existingId = await db.insertTask(Task(name: 'Shared task'));
        await provider.loadRootTasks();
      });
      await pumpAndLoad(tester, buildTestWidget());

      // Drill into the parent so parentId != null (Add here branch).
      await tester.tap(find.text('My Project'));
      await pumpAsync(tester);

      await tapSuggestion(tester, 'Shared task', 'Add here');

      final children =
          await tester.runAsync(() => db.getChildren(parentId)) ?? [];
      expect(children.map((t) => t.id), contains(existingId),
          reason: 'existing task linked under the drilled-in parent');
      final all = await tester.runAsync(() => db.getAllTasks());
      expect(all!.where((t) => t.name == 'Shared task'), hasLength(1),
          reason: 'no duplicate created');
    });

    // [Mechanism] The "Added … here" snackbar offers Undo, which removes the
    // link (removeParentFromTask) — the existing task is no longer a child of
    // the parent it was just linked under.
    testWidgets('under a parent: Add here offers Undo that removes the link',
        (tester) async {
      late int parentId;
      late int existingId;
      await tester.runAsync(() async {
        parentId = await db.insertTask(Task(name: 'My Project'));
        existingId = await db.insertTask(Task(name: 'Shared task'));
        await provider.loadRootTasks();
      });
      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('My Project'));
      await pumpAsync(tester);
      await tapSuggestion(tester, 'Shared task', 'Add here');

      // Linked, and the Undo affordance is present.
      var children = await tester.runAsync(() => db.getChildren(parentId)) ?? [];
      expect(children.map((t) => t.id), contains(existingId));
      // Settle the snackbar slide-in so the Undo action is at its final,
      // hittable position (pumpAsync advances no fake time).
      await tester.pumpAndSettle();
      expect(find.text('Undo'), findsOneWidget);

      await tester.tap(find.text('Undo'), warnIfMissed: false);
      await pumpAsync(tester);

      // The link is gone; the task itself still exists (only the edge removed).
      children = await tester.runAsync(() => db.getChildren(parentId)) ?? [];
      expect(children.map((t) => t.id), isNot(contains(existingId)));
      final all = await tester.runAsync(() => db.getAllTasks());
      expect(all!.where((t) => t.name == 'Shared task'), hasLength(1));
    });

    // [Regression — CR I-55] "Add here" on an Inbox task linked it under the
    // parent but left its Inbox flag set, so it showed in both places. Undo
    // must put it back in the Inbox.
    testWidgets('under a parent: Add here on an Inbox task files it, and Undo '
        'returns it to the Inbox', (tester) async {
      late int parentId;
      late int inboxId;
      await tester.runAsync(() async {
        parentId = await db.insertTask(Task(name: 'Groceries'));
        inboxId = await db.insertTask(Task(name: 'Buy milk', isInbox: true));
        await provider.loadRootTasks();
      });
      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('Groceries'));
      await pumpAsync(tester);
      await tapSuggestion(tester, 'Buy milk', 'Add here');

      var task = await tester.runAsync(() => db.getTaskById(inboxId));
      expect(task!.isInbox, isFalse);
      expect(await tester.runAsync(() => db.getInboxCount()), 0);

      await tester.pumpAndSettle();
      await tester.tap(find.text('Undo'), warnIfMissed: false);
      await pumpAsync(tester);

      task = await tester.runAsync(() => db.getTaskById(inboxId));
      expect(task!.isInbox, isTrue);
      final children =
          await tester.runAsync(() => db.getChildren(parentId)) ?? [];
      expect(children.map((t) => t.id), isNot(contains(inboxId)));
    });

    // [Regression — CR M-53] Linking a task under a pinned leaf makes the leaf
    // a parent, and Today's 5 drops it. Undo removed the link but did not pin
    // the leaf again.
    testWidgets('under a pinned parent: Undo of Add here pins the parent again',
        (tester) async {
      late int parentId;
      await tester.runAsync(() async {
        parentId = await db.insertTask(Task(name: 'Pinned leaf'));
        await db.insertTask(Task(name: 'Shared task'));
        await db.saveTodaysFiveState(
          date: todayDateKey(),
          taskIds: [parentId],
          completedIds: const {},
          workedOnIds: const {},
          pinnedIds: {parentId},
        );
        await provider.loadRootTasks();
      });
      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('Pinned leaf'));
      await pumpAsync(tester);
      await tester.tap(find.byIcon(Icons.add));
      await pumpAsync(tester);
      await tester.tap(find.text('Add anyway'));
      await pumpAsync(tester);
      await tester.enterText(find.byType(TextField).first, 'Shared task');
      await pumpAsync(tester);
      await tester.tap(find.byIcon(Icons.info_outline));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.byWidgetPredicate(
            (w) => w is PopupMenuItem<Task> && w.enabled));
      });
      await pumpAsync(tester);

      // Today's 5 drops the parent once it has a child.
      await tester.runAsync(() => db.saveTodaysFiveState(
            date: todayDateKey(),
            taskIds: const [],
            completedIds: const {},
            workedOnIds: const {},
          ));

      await tester.pumpAndSettle();
      await tester.tap(find.text('Undo'), warnIfMissed: false);
      await pumpAsync(tester);

      final saved =
          await tester.runAsync(() => db.loadTodaysFiveState(todayDateKey()));
      expect(saved?.taskIds, contains(parentId));
      expect(saved?.pinnedIds, contains(parentId));
    });

    // [Edge case — Codex P2] Typing the name of a task that is ALREADY a child
    // of the drilled-in parent must NOT wire a destructive Undo. Re-linking is a
    // no-op (INSERT-OR-IGNORE) that would report ok, and its Undo would remove
    // the PRE-EXISTING edge — deleting the existing child. Guard short-circuits
    // with an "already listed here" message and leaves the edge intact.
    testWidgets('under a parent: Add here on an existing child is a safe no-op',
        (tester) async {
      late int parentId;
      late int childId;
      await tester.runAsync(() async {
        parentId = await db.insertTask(Task(name: 'My Project'));
        childId = await db.insertTask(Task(name: 'Existing child'));
        await db.addRelationship(parentId, childId);
        await provider.loadRootTasks();
      });
      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('My Project'));
      await pumpAsync(tester);
      await tapSuggestion(tester, 'Existing child', 'Add here');

      // Guarded: an "already listed" message, and crucially NO Undo (which would
      // have removed the pre-existing edge).
      expect(find.textContaining('already listed here'), findsOneWidget);
      expect(find.text('Undo'), findsNothing);
      final children = await tester.runAsync(() => db.getChildren(parentId)) ?? [];
      expect(children.map((t) => t.id), contains(childId),
          reason: 'the pre-existing child edge is preserved');
    });

    // [Edge case] Typing the drilled-in parent's OWN name matches itself; the
    // guard (existing.id == parentId) must refuse to self-parent and show the
    // "that's the task you're already in" snackbar rather than link a task to
    // itself.
    testWidgets('under a parent: typing its own name refuses to self-parent',
        (tester) async {
      late int parentId;
      await tester.runAsync(() async {
        parentId = await db.insertTask(Task(name: 'My Project'));
        final childId = await db.insertTask(Task(name: 'A child'));
        await db.addRelationship(parentId, childId);
        await provider.loadRootTasks();
      });
      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.text('My Project'));
      await pumpAsync(tester);

      await tapSuggestion(tester, 'My Project', 'Add here');

      expect(find.textContaining("task you"), findsOneWidget);
      // No self-loop edge was created.
      final parentsOfSelf =
          await tester.runAsync(() => db.getParentIds(parentId)) ?? [];
      expect(parentsOfSelf, isEmpty);
    });

    // [Edge case] "Add here" delegates to addParentToTask which returns false
    // when the link would create a cycle (the existing task is an ancestor of
    // the current parent). The screen must surface the "would create a loop"
    // message and leave the graph unchanged.
    testWidgets('under a parent: linking an ancestor shows the loop warning',
        (tester) async {
      late int grandparentId;
      late int parentId;
      await tester.runAsync(() async {
        grandparentId = await db.insertTask(Task(name: 'Grandparent'));
        parentId = await db.insertTask(Task(name: 'Parent'));
        await db.addRelationship(grandparentId, parentId);
        await provider.loadRootTasks();
      });
      await pumpAndLoad(tester, buildTestWidget());

      // Drill Grandparent → Parent.
      await tester.tap(find.text('Grandparent'));
      await pumpAsync(tester);
      await tester.tap(find.text('Parent'));
      await pumpAsync(tester);

      // Adding Grandparent under Parent would form a cycle.
      await tapSuggestion(tester, 'Grandparent', 'Add here');

      expect(find.textContaining('loop'), findsOneWidget);
      // Grandparent did NOT gain Parent as a new parent.
      final gpParents =
          await tester.runAsync(() => db.getParentIds(grandparentId)) ?? [];
      expect(gpParents, isNot(contains(parentId)));
    });
  });

  // ---------------------------------------------------------------------------
  // App bar search — routed through the shared showTaskSearch helper
  // ---------------------------------------------------------------------------
  // `feature/search-in-all-tabs` moved this screen's home-grown search body
  // into `lib/widgets/task_search.dart` (`showTaskSearch`) so the Starred and
  // Today's 5 tabs could reuse it. All Tasks is the ORIGINAL caller and the one
  // whose behaviour must not have drifted: it navigates in place (no
  // `onNavigateToTask` callback) and its create-from-search still goes through
  // `_runAddFlow(atRoot: true)`. These are refactor guards.
  group('TaskListScreen - search (shared showTaskSearch flow)', () {
    /// Types into the picker's search field and lets its 200ms debounce fire.
    /// pumpAsync pumps without advancing the fake clock, so the debounce Timer
    /// would never run and the filter would stay stale.
    Future<void> search(WidgetTester tester, String query) async {
      await tester.enterText(find.byType(TextField).first, query);
      await tester.pump(const Duration(milliseconds: 300));
      await pumpAsync(tester);
    }

    // [Regression] End-to-end for the dropped-Inbox-toggle bug, through the real
    // AddTaskDialog → SwitchToBrainDump → AddTaskFlow → BrainDumpDialog chain
    // (the unit tests in small_widgets_test.dart cover each seam in isolation).
    // Before: turning Inbox OFF at root and then tapping "Add multiple" reopened
    // the brain dump with Inbox back ON, so the whole batch was filed into the
    // Inbox against the user's choice. After: every task lands outside the Inbox.
    testWidgets('Inbox OFF survives the switch to "Add multiple"',
        (tester) async {
      await tester.runAsync(() => provider.loadRootTasks());
      await pumpAndLoad(tester, buildTestWidget());

      // Root level, so the "+" FAB's dialog offers the Inbox toggle.
      await tester.tap(find.byType(FloatingActionButton));
      await pumpAsync(tester);
      expect(find.text('Inbox'), findsOneWidget);

      // Turn Inbox OFF, then switch to the brain dump.
      await tester.tap(find.text('Inbox'));
      await pumpAsync(tester);
      await tester.tap(find.text('Add multiple'));
      await pumpAsync(tester);

      await tester.enterText(
          find.byType(TextField).first, 'Batch one\nBatch two');
      await pumpAsync(tester);
      await tester.runAsync(() async {
        await tester.tap(find.textContaining('Add'));
      });
      await pumpAsync(tester);

      final all = await tester.runAsync(() => db.getAllTasks()) ?? [];
      final batch =
          all.where((t) => t.name.startsWith('Batch ')).toList();
      expect(batch.length, 2, reason: 'both lines created');
      for (final t in batch) {
        expect(t.isInbox, isFalse,
            reason: '"${t.name}" must honour the Inbox-OFF choice');
      }
    });

    // [Regression] The app bar search action still opens the "Search tasks"
    // picker after the body was extracted into the shared helper.
    testWidgets('app bar search icon opens the "Search tasks" dialog',
        (tester) async {
      await tester.runAsync(() async {
        await db.insertTask(Task(name: 'Write report'));
        await provider.loadRootTasks();
      });
      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.byIcon(Icons.search));
      await pumpAsync(tester);

      expect(find.text('Search tasks'), findsOneWidget);
    });

    // [Regression] All Tasks drills into the pick ITSELF (currentParent), unlike
    // the other two tabs which hand it to onNavigateToTask. Guards the
    // `onSelected: navigateToTask` wiring of the extracted helper.
    testWidgets('picking a result drills into it in place', (tester) async {
      await tester.runAsync(() async {
        final parentId = await db.insertTask(Task(name: 'Deep parent'));
        final childId = await db.insertTask(Task(name: 'Deep child'));
        await db.addRelationship(parentId, childId);
        await provider.loadRootTasks();
      });
      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.byIcon(Icons.search));
      await pumpAsync(tester);
      await search(tester, 'Deep child');
      await tester.tap(find.text('Deep child').last);
      await pumpAsync(tester);

      expect(provider.currentParent, isNotNull,
          reason: 'All Tasks opens the result in place, not via a callback');
      expect(provider.currentParent!.name, 'Deep child');
    });

    // [Regression] Search is GLOBAL, so create-from-search files at root even
    // while the tab is drilled into a parent (`_runAddFlow(atRoot: true)`) — the
    // opposite of the "+" FAB, which nests under the open task. This is the one
    // behaviour most easily lost when rerouting through a shared helper.
    testWidgets('create-from-search files at root while drilled into a parent',
        (tester) async {
      late int parentId;
      await tester.runAsync(() async {
        parentId = await db.insertTask(Task(name: 'Open project'));
        final childId = await db.insertTask(Task(name: 'Existing child'));
        await db.addRelationship(parentId, childId);
        await provider.loadRootTasks();
      });
      await pumpAndLoad(tester, buildTestWidget());

      // Drill in so there IS a current parent to (wrongly) capture the add.
      await tester.tap(find.text('Open project'));
      await pumpAsync(tester);
      expect(provider.currentParent!.name, 'Open project');

      await tester.tap(find.byIcon(Icons.search));
      await pumpAsync(tester);
      await search(tester, 'Global capture');
      await tester.tap(find.textContaining('Create'));
      await pumpAsync(tester);

      expect(find.text('Add Task'), findsOneWidget);
      // Inbox toggle is offered because the add lands at root.
      expect(find.text('Inbox'), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.text('Add'));
      });
      await pumpAsync(tester);

      final created = await tester.runAsync(() async {
        final all = await db.getAllTasks();
        return all.firstWhere((t) => t.name == 'Global capture');
      });
      final parents =
          await tester.runAsync(() => db.getParentIds(created!.id!)) ?? [];
      expect(parents, isEmpty,
          reason: 'search create must ignore the drilled-in parent');
      expect(parents, isNot(contains(parentId)));
    });
  });

  group('Round 12 review fixes', () {
    // [Regression — CR I-55] "Also show under..." on an Inbox task called
    // addParentToTask, which kept the Inbox flag, so the task showed under the
    // new parent and in the Inbox.
    testWidgets('"Also show under..." on an Inbox task files it',
        (tester) async {
      late int groceriesId;
      late int inboxId;
      await tester.runAsync(() async {
        groceriesId = await db.insertTask(Task(name: 'Groceries'));
        inboxId = await db.insertTask(Task(name: 'Buy milk', isInbox: true));
        await provider.loadRootTasks();
        final inboxTask = await db.getTaskById(inboxId);
        await provider.navigateInto(inboxTask!);
      });
      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.byIcon(Icons.more_vert));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Also show under...'));
      await pumpAsync(tester);
      await tester.enterText(find.byType(TextField).first, 'Groceries');
      await tester.pump(const Duration(milliseconds: 300));
      await pumpAsync(tester);
      await tester.tap(find.text('Groceries').last);
      await pumpAsync(tester);

      final task = await tester.runAsync(() => db.getTaskById(inboxId));
      expect(task!.isInbox, isFalse);
      final parents =
          await tester.runAsync(() => db.getParentIds(inboxId)) ?? [];
      expect(parents, [groceriesId]);
    });

    // [Edge case — CR M-61] A database error while loading the search pool
    // escaped every caller. It now closes the spinner and shows a snackbar.
    testWidgets('a failed search load shows a snackbar and no picker',
        (tester) async {
      provider = _SearchLoadProvider()..error = StateError('db closed');
      await tester.runAsync(() => provider.loadRootTasks());
      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.byIcon(Icons.search));
      await pumpAsync(tester);

      expect(find.text("Couldn't load tasks — please retry"), findsOneWidget);
      expect(find.text('Search tasks'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byType(TaskListScreen), findsOneWidget);
    });

    // [Regression — CR M-61] Android Back closed the spinner mid-fetch, and
    // the `finally` pop then closed the route under it: the home route.
    // Back is now ignored until the fetch ends.
    testWidgets('Back during the search spinner keeps the home route',
        (tester) async {
      final gated = _SearchLoadProvider()..gate = Completer<void>();
      provider = gated;
      await tester.runAsync(() async {
        await db.insertTask(Task(name: 'Write report'));
        await provider.loadRootTasks();
      });
      await pumpAndLoad(tester, buildTestWidget());

      await tester.tap(find.byIcon(Icons.search));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget,
          reason: 'Back must not close the spinner');

      gated.gate!.complete();
      await pumpAsync(tester);

      expect(find.text('Search tasks'), findsOneWidget);
      expect(find.byType(TaskListScreen), findsOneWidget);
    });
  });

  group('Rename', () {
    /// Types [name] into the open Rename dialog and taps its Rename button.
    ///
    /// The dialog's exit transition runs to the end before the database
    /// write is let through. _renameTask disposes its TextEditingController
    /// only after that write, so the controller outlives the dialog here. The
    /// skipped Cancel test below covers the case where it does not.
    Future<void> submitRename(WidgetTester tester, String name) async {
      await tester.enterText(
          find.descendant(
              of: find.byType(AlertDialog), matching: find.byType(TextField)),
          name);
      await tester.tap(find.widgetWithText(TextButton, 'Rename'));
      await tester.pumpAndSettle();
      await settle(tester);
    }

    testWidgets('card menu Rename saves the new name and updates the card',
        (tester) async {
      late int id;
      await tester.runAsync(() async {
        id = await db.insertTask(Task(name: 'Old name'));
        await provider.loadRootTasks();
      });
      await pumpTall(tester);

      await cardAction(tester, 'Old name', 'Rename');
      expect(find.byType(AlertDialog), findsOneWidget);
      await submitRename(tester, 'New name');

      final task = await tester.runAsync(() => db.getTaskById(id));
      expect(task!.name, 'New name');
      expect(find.text('New name'), findsOneWidget);
      expect(find.text('Old name'), findsNothing);
    });

    // [Bug] _renameTask (task_list_screen.dart:608-610) disposes the dialog's
    // TextEditingController in `finally` as soon as showDialog's future
    // completes. On Cancel (or an unchanged name) that is the moment the route
    // pops, while the dialog's exit transition is still building the
    // TextField. Flutter then reports "A TextEditingController was used after
    // being disposed" (debug builds), followed by framework assertions that
    // leave the widget tree broken for the rest of the test run. Correct
    // behaviour: the dialog closes with no error, so the controller must be
    // disposed only after the route has finished its exit transition.
    testWidgets('Cancel leaves the name unchanged and reports no error',
        skip: true, // Bug: the Rename dialog's controller is disposed while
        // the dialog is still closing. See the comment above.
        (tester) async {
      late int id;
      await tester.runAsync(() async {
        id = await db.insertTask(Task(name: 'Keep me'));
        await provider.loadRootTasks();
      });
      await pumpTall(tester);

      await cardAction(tester, 'Keep me', 'Rename');
      await tester.enterText(
          find.descendant(
              of: find.byType(AlertDialog), matching: find.byType(TextField)),
          'Discarded');
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await settle(tester);

      expect(tester.takeException(), isNull);
      final task = await tester.runAsync(() => db.getTaskById(id));
      expect(task!.name, 'Keep me');
      expect(find.text('Keep me'), findsOneWidget);
    });

    // The provider must rebuild _currentParent on rename; otherwise the app
    // bar title of the open task keeps the old name.
    testWidgets('overflow Rename on the open task updates the app bar title',
        (tester) async {
      late int parentId;
      await tester.runAsync(() async {
        parentId = await db.insertTask(Task(name: 'Project'));
        final childId = await db.insertTask(Task(name: 'Step'));
        await db.addRelationship(parentId, childId);
        await provider.loadRootTasks();
      });
      await pumpTall(tester);
      await tester.tap(find.text('Project'));
      await pumpAsync(tester);

      await overflowAction(tester, 'Rename');
      await submitRename(tester, 'Renamed project');

      final task = await tester.runAsync(() => db.getTaskById(parentId));
      expect(task!.name, 'Renamed project');
      expect(find.widgetWithText(AppBar, 'Renamed project'), findsOneWidget);
      expect(find.text('Project'), findsNothing);
    });

    testWidgets('tapping the name in the leaf detail renames the leaf',
        (tester) async {
      late int id;
      await tester.runAsync(() async {
        id = await db.insertTask(Task(name: 'Leaf'));
        await provider.loadRootTasks();
      });
      await pumpTall(tester);
      await tester.tap(find.text('Leaf'));
      await pumpAsync(tester);

      await tester.tap(find.byIcon(Icons.edit_outlined));
      await settle(tester);
      await submitRename(tester, 'Leaf renamed');

      final task = await tester.runAsync(() => db.getTaskById(id));
      expect(task!.name, 'Leaf renamed');
      expect(find.text('Leaf renamed'), findsWidgets);
      expect(find.text('Leaf'), findsNothing);
    });
  });

  group('Delete with Undo', () {
    testWidgets('deleting a leaf card needs no dialog, and Undo restores it',
        (tester) async {
      await tester.runAsync(() async {
        await db.insertTask(Task(name: 'Doomed'));
        await db.insertTask(Task(name: 'Other'));
        await provider.loadRootTasks();
      });
      await pumpTall(tester);

      await cardAction(tester, 'Doomed', 'Delete "Doomed"');

      expect(find.byType(DeleteTaskDialog), findsNothing);
      var names = (await tester.runAsync(() => db.getAllTasks()))!
          .map((t) => t.name);
      expect(names, isNot(contains('Doomed')));
      expect(find.text('Doomed'), findsNothing);
      expect(find.text('Deleted "Doomed"'), findsOneWidget);

      await tapUndo(tester);

      names = (await tester.runAsync(() => db.getAllTasks()))!
          .map((t) => t.name);
      expect(names, contains('Doomed'));
      expect(find.text('Doomed'), findsOneWidget);
    });

    testWidgets('"Keep sub-tasks" moves the children up, and Undo nests them '
        'again', (tester) async {
      late int parentId;
      late int childId;
      await tester.runAsync(() async {
        parentId = await db.insertTask(Task(name: 'Parent'));
        childId = await db.insertTask(Task(name: 'Child'));
        await db.addRelationship(parentId, childId);
        await provider.loadRootTasks();
      });
      await pumpTall(tester);

      await cardAction(tester, 'Parent', 'Delete "Parent"');
      expect(find.byType(DeleteTaskDialog), findsOneWidget);
      await tester.tap(find.text('Keep sub-tasks'));
      await settle(tester);

      expect(await tester.runAsync(() => db.getTaskById(parentId)), isNull);
      final roots = (await tester.runAsync(() => db.getRootTasks()))!;
      expect(roots.map((t) => t.id), [childId]);
      expect(find.text('Child'), findsOneWidget,
          reason: 'the child is now a top-level card');
      expect(find.text('Parent'), findsNothing);
      expect(find.text('Deleted "Parent"'), findsOneWidget);

      await tapUndo(tester);

      expect(await tester.runAsync(() => db.getParentIds(childId)),
          [parentId]);
      expect(find.text('Parent'), findsOneWidget);
      expect(find.text('Child'), findsNothing,
          reason: 'the child is nested under Parent again');
    });

    testWidgets('"Delete everything" removes the subtree, and Undo restores it',
        (tester) async {
      late int parentId;
      late int childId;
      await tester.runAsync(() async {
        parentId = await db.insertTask(Task(name: 'Parent'));
        childId = await db.insertTask(Task(name: 'Child'));
        await db.addRelationship(parentId, childId);
        await db.insertTask(Task(name: 'Bystander'));
        await provider.loadRootTasks();
      });
      await pumpTall(tester);

      await cardAction(tester, 'Parent', 'Delete "Parent"');
      await tester.tap(find.text('Delete everything'));
      await settle(tester);

      expect(await tester.runAsync(() => db.getTaskById(parentId)), isNull);
      expect(await tester.runAsync(() => db.getTaskById(childId)), isNull);
      expect(find.text('Parent'), findsNothing);
      expect(find.text('Bystander'), findsOneWidget);
      expect(find.text('Deleted "Parent" and 1 sub-task'), findsOneWidget);

      await tapUndo(tester);

      expect(await tester.runAsync(() => db.getTaskById(parentId)), isNotNull);
      expect(await tester.runAsync(() => db.getParentIds(childId)),
          [parentId]);
      expect(find.text('Parent'), findsOneWidget);
    });

    testWidgets('Cancel in the delete dialog deletes nothing', (tester) async {
      late int parentId;
      await tester.runAsync(() async {
        parentId = await db.insertTask(Task(name: 'Parent'));
        final childId = await db.insertTask(Task(name: 'Child'));
        await db.addRelationship(parentId, childId);
        await provider.loadRootTasks();
      });
      await pumpTall(tester);

      await cardAction(tester, 'Parent', 'Delete "Parent"');
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await settle(tester);

      expect(await tester.runAsync(() => db.getTaskById(parentId)), isNotNull);
      expect(find.text('Parent'), findsOneWidget);
      expect(find.textContaining('Deleted'), findsNothing);
    });

    testWidgets('deleting the open task from the overflow menu goes back up',
        (tester) async {
      late int parentId;
      await tester.runAsync(() async {
        parentId = await db.insertTask(Task(name: 'Project'));
        final childId = await db.insertTask(Task(name: 'Step'));
        await db.addRelationship(parentId, childId);
        await db.insertTask(Task(name: 'Other'));
        await provider.loadRootTasks();
      });
      await pumpTall(tester);
      await tester.tap(find.text('Project'));
      await pumpAsync(tester);

      await overflowAction(tester, 'Delete');
      await tester.tap(find.text('Delete everything'));
      await settle(tester);

      expect(await tester.runAsync(() => db.getTaskById(parentId)), isNull);
      expect(provider.isRoot, isTrue);
      expect(find.text('Task Roulette'), findsOneWidget);
      expect(find.text('Other'), findsOneWidget);
      expect(find.text('Project'), findsNothing);
    });

    testWidgets('deleting the open leaf goes back up, and Undo restores it',
        (tester) async {
      late int leafId;
      await tester.runAsync(() async {
        leafId = await db.insertTask(Task(name: 'Open leaf'));
        await db.insertTask(Task(name: 'Other'));
        await provider.loadRootTasks();
      });
      await pumpTall(tester);
      await tester.tap(find.text('Open leaf'));
      await pumpAsync(tester);

      await overflowAction(tester, 'Delete');

      expect(find.byType(DeleteTaskDialog), findsNothing);
      expect(await tester.runAsync(() => db.getTaskById(leafId)), isNull);
      expect(provider.isRoot, isTrue);
      expect(find.text('Open leaf'), findsNothing);
      expect(find.text('Deleted "Open leaf"'), findsOneWidget);

      await tapUndo(tester);

      expect(await tester.runAsync(() => db.getTaskById(leafId)), isNotNull);
      expect(find.text('Open leaf'), findsOneWidget);
    });
  });

  group('Star', () {
    testWidgets('app bar star toggles the open task and its icon',
        (tester) async {
      late int parentId;
      await tester.runAsync(() async {
        parentId = await db.insertTask(Task(name: 'Project'));
        final childId = await db.insertTask(Task(name: 'Step'));
        await db.addRelationship(parentId, childId);
        await provider.loadRootTasks();
      });
      await pumpTall(tester);
      await tester.tap(find.text('Project'));
      await pumpAsync(tester);

      await tester.tap(find.byTooltip('Star'));
      await settle(tester);

      var task = await tester.runAsync(() => db.getTaskById(parentId));
      expect(task!.isStarred, isTrue);
      expect(find.byTooltip('Unstar'), findsOneWidget);
      expect(find.byIcon(Icons.star), findsOneWidget);

      await tester.tap(find.byTooltip('Unstar'));
      await settle(tester);

      task = await tester.runAsync(() => db.getTaskById(parentId));
      expect(task!.isStarred, isFalse);
      expect(find.byTooltip('Star'), findsOneWidget);
    });

    testWidgets('card menu Star stars the task and the card shows it',
        (tester) async {
      late int id;
      await tester.runAsync(() async {
        id = await db.insertTask(Task(name: 'Favourite'));
        await provider.loadRootTasks();
      });
      await pumpTall(tester);

      await cardAction(tester, 'Favourite', 'Star');

      final task = await tester.runAsync(() => db.getTaskById(id));
      expect(task!.isStarred, isTrue);
      expect(cardFor(tester, 'Favourite').isStarred, isTrue);

      // The sheet now offers the opposite action.
      await tester.longPress(find.text('Favourite'));
      await tester.pumpAndSettle();
      expect(find.text('Unstar'), findsOneWidget);
    });
  });

  group('Inbox section', () {
    testWidgets('tapping the header collapses and expands the Inbox',
        (tester) async {
      await tester.runAsync(() async {
        await db.insertTask(Task(name: 'Regular'));
        await db.insertTask(Task(name: 'Buy milk', isInbox: true));
        await provider.loadRootTasks();
      });
      await pumpTall(tester);

      expect(find.text('Inbox (1)'), findsOneWidget);
      expect(find.text('Buy milk'), findsOneWidget);

      await tester.tap(find.text('Inbox (1)'));
      await tester.pump();
      expect(find.text('Buy milk'), findsNothing);
      expect(find.byIcon(Icons.expand_more), findsOneWidget);

      await tester.tap(find.text('Inbox (1)'));
      await tester.pump();
      expect(find.text('Buy milk'), findsOneWidget);
    });

    testWidgets('long-pressing an Inbox task opens it', (tester) async {
      await tester.runAsync(() async {
        await db.insertTask(Task(name: 'Regular'));
        await db.insertTask(Task(name: 'Buy milk', isInbox: true));
        await provider.loadRootTasks();
      });
      await pumpTall(tester);

      await tester.longPress(find.text('Buy milk'));
      await settle(tester);

      expect(provider.currentParent?.name, 'Buy milk');
      expect(find.text('Done today'), findsOneWidget);
    });

    testWidgets('"Keep at top level" leaves the Inbox, and Undo puts it back',
        (tester) async {
      late int inboxId;
      await tester.runAsync(() async {
        await db.insertTask(Task(name: 'Regular'));
        inboxId = await db.insertTask(Task(name: 'Buy milk', isInbox: true));
        await provider.loadRootTasks();
      });
      await pumpTall(tester);

      await tester.tap(find.text('Buy milk'));
      await settle(tester);
      expect(find.byType(TriageDialog), findsOneWidget);
      await tester.tap(find.text('Keep at top level'));
      await settle(tester);

      var task = await tester.runAsync(() => db.getTaskById(inboxId));
      expect(task!.isInbox, isFalse);
      expect(find.textContaining('Inbox ('), findsNothing);
      expect(find.byWidgetPredicate((w) => w is TaskCard && w.task.id == inboxId),
          findsOneWidget,
          reason: 'the task is a grid card now');
      expect(find.text('Kept "Buy milk" at top level'), findsOneWidget);

      await tapUndo(tester);

      task = await tester.runAsync(() => db.getTaskById(inboxId));
      expect(task!.isInbox, isTrue);
      expect(find.text('Inbox (1)'), findsOneWidget);
    });

    testWidgets('filing under a task links it there, and Undo returns it to '
        'the Inbox', (tester) async {
      late int groceriesId;
      late int inboxId;
      await tester.runAsync(() async {
        groceriesId = await db.insertTask(Task(name: 'Groceries'));
        inboxId = await db.insertTask(Task(name: 'Buy milk', isInbox: true));
        await provider.loadRootTasks();
      });
      await pumpTall(tester);

      await tester.tap(find.text('Buy milk'));
      await settle(tester);
      // The dialog opens on Suggestions when it has any, else on Browse.
      if (find.text('Browse').evaluate().isNotEmpty) {
        await tester.tap(find.text('Browse'));
        await settle(tester);
      }
      await tester.tap(find.byTooltip('Place here'));
      await settle(tester);

      var task = await tester.runAsync(() => db.getTaskById(inboxId));
      expect(task!.isInbox, isFalse);
      expect(await tester.runAsync(() => db.getParentIds(inboxId)),
          [groceriesId]);
      expect(find.textContaining('Inbox ('), findsNothing);
      expect(find.text('Buy milk'), findsNothing);
      expect(find.text('Filed "Buy milk" under "Groceries"'), findsOneWidget);

      await tapUndo(tester);

      task = await tester.runAsync(() => db.getTaskById(inboxId));
      expect(task!.isInbox, isTrue);
      expect(await tester.runAsync(() => db.getParentIds(inboxId)), isEmpty);
      expect(find.text('Inbox (1)'), findsOneWidget);
    });

    testWidgets('"File all" walks every Inbox task and reports a clear Inbox',
        (tester) async {
      await tester.runAsync(() async {
        await db.insertTask(Task(name: 'Regular'));
        await db.insertTask(Task(name: 'Inbox A', isInbox: true));
        await db.insertTask(Task(name: 'Inbox B', isInbox: true));
        await provider.loadRootTasks();
      });
      await pumpTall(tester);

      expect(find.text('Inbox (2)'), findsOneWidget);
      await tester.tap(find.text('File all'));
      await settle(tester);
      expect(find.text('+1 more'), findsOneWidget);
      await tester.tap(find.text('Keep at top level'));
      await settle(tester);
      expect(find.byType(TriageDialog), findsOneWidget,
          reason: 'the second Inbox task is offered next');
      await tester.tap(find.text('Keep at top level'));
      await settle(tester);

      expect(await tester.runAsync(() => db.getInboxCount()), 0);
      expect(find.byType(TriageDialog), findsNothing);
      expect(find.text('Inbox cleared!'), findsOneWidget);
      expect(find.textContaining('Inbox ('), findsNothing);
    });

    testWidgets('closing the dialog stops "File all" with the rest unfiled',
        (tester) async {
      await tester.runAsync(() async {
        await db.insertTask(Task(name: 'Regular'));
        await db.insertTask(Task(name: 'Inbox A', isInbox: true));
        await db.insertTask(Task(name: 'Inbox B', isInbox: true));
        await provider.loadRootTasks();
      });
      await pumpTall(tester);

      await tester.tap(find.text('File all'));
      await settle(tester);
      // Tap the barrier outside the dialog.
      await tester.tapAt(const Offset(5, 5));
      await settle(tester);

      expect(find.byType(TriageDialog), findsNothing);
      expect(await tester.runAsync(() => db.getInboxCount()), 2);
      expect(find.text('Inbox cleared!'), findsNothing);
      expect(find.text('Inbox (2)'), findsOneWidget);
    });
  });

  group('Flare spotlight', () {
    TaskCard spotlitCard(WidgetTester tester) => tester.widget<TaskCard>(
        find.descendant(
            of: find.byType(SpotlightOverlay),
            matching: find.byType(TaskCard)));

    testWidgets('Flare spotlights a card, and Open drills into it',
        (tester) async {
      await tester.runAsync(() async {
        await db.insertTask(Task(name: 'Only task'));
        await provider.loadRootTasks();
      });
      await pumpTall(tester);

      await tester.tap(find.byIcon(Icons.flare));
      await settle(tester);

      expect(find.byType(SpotlightOverlay), findsOneWidget);
      expect(spotlitCard(tester).task.name, 'Only task');
      // A leaf with no siblings: nothing deeper, nothing else to spin.
      expect(find.byTooltip('Spin Deeper'), findsNothing);

      await tester.tap(find.byTooltip('Open'));
      await settle(tester);

      expect(find.byType(SpotlightOverlay), findsNothing);
      expect(provider.currentParent?.name, 'Only task');
    });

    testWidgets('Spin Again moves the spotlight to the other task',
        (tester) async {
      await tester.runAsync(() async {
        await db.insertTask(Task(name: 'Alpha'));
        await db.insertTask(Task(name: 'Beta'));
        await provider.loadRootTasks();
      });
      await pumpTall(tester);

      await tester.tap(find.byIcon(Icons.flare));
      await settle(tester);
      final first = spotlitCard(tester).task.name;

      await tester.tap(find.byTooltip('Spin Again'));
      await settle(tester);

      final second = spotlitCard(tester).task.name;
      expect({first, second}, {'Alpha', 'Beta'});
    });

    testWidgets('Spin Deeper opens the task and spotlights one of its children',
        (tester) async {
      await tester.runAsync(() async {
        final parentId = await db.insertTask(Task(name: 'Project'));
        final childId = await db.insertTask(Task(name: 'Step'));
        await db.addRelationship(parentId, childId);
        await provider.loadRootTasks();
      });
      await pumpTall(tester);

      await tester.tap(find.byIcon(Icons.flare));
      await settle(tester);
      expect(spotlitCard(tester).task.name, 'Project');

      await tester.tap(find.byTooltip('Spin Deeper'));
      await settle(tester);

      expect(provider.currentParent?.name, 'Project');
      expect(find.byType(SpotlightOverlay), findsOneWidget);
      expect(spotlitCard(tester).task.name, 'Step');
    });

    testWidgets('tapping the dimmed backdrop dismisses the spotlight',
        (tester) async {
      await tester.runAsync(() async {
        await db.insertTask(Task(name: 'Only task'));
        await provider.loadRootTasks();
      });
      await pumpTall(tester);

      await tester.tap(find.byIcon(Icons.flare));
      await settle(tester);
      await tester.tapAt(const Offset(780, 1000));
      await settle(tester);

      expect(find.byType(SpotlightOverlay), findsNothing);
      expect(provider.isRoot, isTrue);
      expect(find.byIcon(Icons.flare), findsOneWidget);
    });

    testWidgets('Back dismisses the spotlight and stays on the list',
        (tester) async {
      await tester.runAsync(() async {
        await db.insertTask(Task(name: 'Only task'));
        await provider.loadRootTasks();
      });
      await pumpTall(tester);

      await tester.tap(find.byIcon(Icons.flare));
      await settle(tester);
      await tester.binding.handlePopRoute();
      await settle(tester);

      expect(find.byType(SpotlightOverlay), findsNothing);
      expect(find.text('Only task'), findsOneWidget);
    });

    testWidgets('tapping the spotlit card opens it', (tester) async {
      await tester.runAsync(() async {
        await db.insertTask(Task(name: 'Only task'));
        await provider.loadRootTasks();
      });
      await pumpTall(tester);

      await tester.tap(find.byIcon(Icons.flare));
      await settle(tester);
      await tester.tap(find.descendant(
          of: find.byType(SpotlightOverlay), matching: find.byType(TaskCard)));
      await settle(tester);

      expect(find.byType(SpotlightOverlay), findsNothing);
      expect(provider.currentParent?.name, 'Only task');
    });

    testWidgets('with nothing eligible, Flare says so and spotlights nothing',
        (tester) async {
      await tester.runAsync(() async {
        await db.insertTask(Task(
            name: 'Done already',
            lastWorkedAt: DateTime.now().millisecondsSinceEpoch));
        await provider.loadRootTasks();
      });
      await pumpTall(tester);

      await tester.tap(find.byIcon(Icons.flare));
      await settle(tester);

      expect(find.text('No tasks to spin'), findsOneWidget);
      expect(find.byType(SpotlightOverlay), findsNothing);
    });
  });

  group('"Do after" dependencies', () {
    testWidgets('card menu "Do after..." blocks the card behind the pick',
        (tester) async {
      late int aId;
      late int bId;
      await tester.runAsync(() async {
        aId = await db.insertTask(Task(name: 'Paint'));
        bId = await db.insertTask(Task(name: 'Sand'));
        await provider.loadRootTasks();
      });
      await pumpTall(tester);

      await cardAction(tester, 'Paint', 'Do after...');
      expect(find.text('Do "Paint" after...'), findsOneWidget);
      await pickInPicker(tester, 'Sand');

      final deps = await tester.runAsync(() => db.getDependencies(aId));
      expect(deps!.map((t) => t.id), [bId]);
      expect(cardFor(tester, 'Paint').isBlocked, isTrue);
      expect(cardFor(tester, 'Sand').isBlocked, isFalse);
    });

    testWidgets('the picker offers to remove an existing dependency',
        (tester) async {
      late int aId;
      await tester.runAsync(() async {
        aId = await db.insertTask(Task(name: 'Paint'));
        final bId = await db.insertTask(Task(name: 'Sand'));
        await db.addDependency(aId, bId);
        await provider.loadRootTasks();
      });
      await pumpTall(tester);
      expect(cardFor(tester, 'Paint').isBlocked, isTrue);

      await cardAction(tester, 'Paint', 'Do after...');
      await tester.tap(find.text('Remove dependency on "Sand"'));
      await settle(tester);

      expect(await tester.runAsync(() => db.getDependencies(aId)), isEmpty);
      expect(cardFor(tester, 'Paint').isBlocked, isFalse);
    });

    testWidgets('a dependency that would loop is refused', (tester) async {
      late int bId;
      await tester.runAsync(() async {
        final aId = await db.insertTask(Task(name: 'Paint'));
        bId = await db.insertTask(Task(name: 'Sand'));
        await db.addDependency(aId, bId);
        await provider.loadRootTasks();
      });
      await pumpTall(tester);

      await cardAction(tester, 'Sand', 'Do after...');
      await pickInPicker(tester, 'Paint');

      expect(find.text('Cannot add: would create a cycle'), findsOneWidget);
      expect(await tester.runAsync(() => db.getDependencies(bId)), isEmpty);
    });

    testWidgets('overflow "Do after..." adds a dependency to the open task',
        (tester) async {
      late int projectId;
      late int otherId;
      await tester.runAsync(() async {
        projectId = await db.insertTask(Task(name: 'Project'));
        final stepId = await db.insertTask(Task(name: 'Step'));
        await db.addRelationship(projectId, stepId);
        otherId = await db.insertTask(Task(name: 'Other'));
        await provider.loadRootTasks();
      });
      await pumpTall(tester);
      await tester.tap(find.text('Project'));
      await pumpAsync(tester);

      await overflowAction(tester, 'Do after...');
      expect(find.text('Do "Project" after...'), findsOneWidget);
      await pickInPicker(tester, 'Other');

      final deps = await tester.runAsync(() => db.getDependencies(projectId));
      expect(deps!.map((t) => t.id), [otherId]);
    });

    testWidgets('leaf detail "Do after..." shows the new dependency, which '
        'opens the blocker', (tester) async {
      late int leafId;
      late int siblingId;
      await tester.runAsync(() async {
        final parentId = await db.insertTask(Task(name: 'Parent'));
        leafId = await db.insertTask(Task(name: 'Leaf Task'));
        siblingId = await db.insertTask(Task(name: 'Sibling'));
        await db.addRelationship(parentId, leafId);
        await db.addRelationship(parentId, siblingId);
        await provider.loadRootTasks();
      });
      await pumpTall(tester);
      await tester.tap(find.text('Parent'));
      await pumpAsync(tester);
      await tester.tap(find.text('Leaf Task'));
      await pumpAsync(tester);

      await tester.tap(find.byTooltip('Do after...'));
      await settle(tester);
      // The leaf's siblings are listed first.
      await pickInPicker(tester, 'Sibling');

      final deps = await tester.runAsync(() => db.getDependencies(leafId));
      expect(deps!.map((t) => t.id), [siblingId]);
      expect(find.byTooltip('After: Sibling'), findsOneWidget,
          reason: 'the leaf detail shows the new dependency without '
              'navigating away');

      await tester.tap(find.byIcon(Icons.hourglass_top));
      await settle(tester);
      expect(provider.currentParent?.name, 'Sibling');
    });
  });

  group('Move, remove and link', () {
    /// Root "Home" with children "Fix tap" and "Paint wall", plus root
    /// "Garden". Opens Home.
    Future<({int home, int garden, int fixTap})> openHome(
        WidgetTester tester) async {
      late int home;
      late int garden;
      late int fixTap;
      await tester.runAsync(() async {
        home = await db.insertTask(Task(name: 'Home'));
        garden = await db.insertTask(Task(name: 'Garden'));
        fixTap = await db.insertTask(Task(name: 'Fix tap'));
        final paint = await db.insertTask(Task(name: 'Paint wall'));
        await db.addRelationship(home, fixTap);
        await db.addRelationship(home, paint);
        await provider.loadRootTasks();
      });
      await pumpTall(tester);
      await tester.tap(find.text('Home'));
      await pumpAsync(tester);
      return (home: home, garden: garden, fixTap: fixTap);
    }

    testWidgets('"Move to..." relinks the task under the pick',
        (tester) async {
      final ids = await openHome(tester);

      await cardAction(tester, 'Fix tap', 'Move to...');
      expect(find.text('Move "Fix tap" to...'), findsOneWidget);
      await pickInPicker(tester, 'Garden');

      expect(await tester.runAsync(() => db.getParentIds(ids.fixTap)),
          [ids.garden]);
      expect(find.text('Fix tap'), findsNothing);
      expect(find.text('Paint wall'), findsOneWidget);
    });

    testWidgets('"Move to..." into the task\'s own sub-task is refused',
        (tester) async {
      final ids = await openHome(tester);
      late int washerId;
      await tester.runAsync(() async {
        washerId = await db.insertTask(Task(name: 'Buy washer'));
        await db.addRelationship(ids.fixTap, washerId);
        await provider.refreshAfterMutation();
      });
      await pumpAsync(tester);

      await cardAction(tester, 'Fix tap', 'Move to...');
      await pickInPicker(tester, 'Buy washer');

      expect(find.text('Cannot move: would create a cycle'), findsOneWidget);
      expect(await tester.runAsync(() => db.getParentIds(ids.fixTap)),
          [ids.home]);
      expect(find.text('Fix tap'), findsOneWidget);
    });

    testWidgets('Android Back goes up one level', (tester) async {
      await openHome(tester);

      await tester.binding.handlePopRoute();
      await settle(tester);

      expect(provider.isRoot, isTrue);
      expect(find.text('Task Roulette'), findsOneWidget);
      expect(find.text('Garden'), findsOneWidget);
    });

    testWidgets('"Remove from here" on a single-parent task confirms, then '
        'moves it to the top level', (tester) async {
      final ids = await openHome(tester);

      await cardAction(tester, 'Fix tap', 'Remove from here');
      expect(find.text('Move to top level?'), findsOneWidget);
      await tester.tap(find.text('Move to top level'));
      await settle(tester);

      expect(await tester.runAsync(() => db.getParentIds(ids.fixTap)),
          isEmpty);
      expect(find.text('Fix tap'), findsNothing);
      expect(find.text('Paint wall'), findsOneWidget);
    });

    testWidgets('cancelling "Remove from here" keeps the link',
        (tester) async {
      final ids = await openHome(tester);

      await cardAction(tester, 'Fix tap', 'Remove from here');
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await settle(tester);

      expect(await tester.runAsync(() => db.getParentIds(ids.fixTap)),
          [ids.home]);
      expect(find.text('Fix tap'), findsOneWidget);
    });

    testWidgets('"Remove from here" on a multi-parent task unlinks without '
        'asking', (tester) async {
      late int garden;
      late int fixTap;
      await tester.runAsync(() async {
        final home = await db.insertTask(Task(name: 'Home'));
        garden = await db.insertTask(Task(name: 'Garden'));
        fixTap = await db.insertTask(Task(name: 'Fix tap'));
        final paint = await db.insertTask(Task(name: 'Paint wall'));
        await db.addRelationship(home, fixTap);
        await db.addRelationship(home, paint);
        await db.addRelationship(garden, fixTap);
        await provider.loadRootTasks();
      });
      await pumpTall(tester);
      await tester.tap(find.text('Home'));
      await pumpAsync(tester);

      await cardAction(tester, 'Fix tap', 'Remove from here');

      expect(find.text('Move to top level?'), findsNothing);
      expect(await tester.runAsync(() => db.getParentIds(fixTap)), [garden]);
      expect(find.text('Fix tap'), findsNothing);
    });

    testWidgets('card "Also show under..." adds a second parent',
        (tester) async {
      final ids = await openHome(tester);

      await cardAction(tester, 'Fix tap', 'Also show under...');
      expect(find.text('Also show "Fix tap" under...'), findsOneWidget);
      await pickInPicker(tester, 'Garden');

      expect(
          (await tester.runAsync(() => db.getParentIds(ids.fixTap)))!.toSet(),
          {ids.home, ids.garden});
      expect(find.text('Fix tap'), findsOneWidget,
          reason: 'still listed under the open task');
    });

    testWidgets('the link FAB adds an existing task under the open task',
        (tester) async {
      final ids = await openHome(tester);

      await tester.tap(find.byIcon(Icons.playlist_add));
      await settle(tester);
      expect(find.text('Add task under "Home"'), findsOneWidget);
      await pickInPicker(tester, 'Garden');

      final children =
          await tester.runAsync(() => db.getChildren(ids.home)) ?? [];
      expect(children.map((t) => t.id), contains(ids.garden));
      expect(find.text('Garden'), findsOneWidget);
    });

    testWidgets('the link FAB on a pinned task warns first; Cancel stops it',
        (tester) async {
      late int leafId;
      await tester.runAsync(() async {
        leafId = await db.insertTask(Task(name: 'Pinned leaf'));
        await db.insertTask(Task(name: 'Other'));
        await db.saveTodaysFiveState(
          date: todayDateKey(),
          taskIds: [leafId],
          completedIds: const {},
          workedOnIds: const {},
          pinnedIds: {leafId},
        );
        await provider.loadRootTasks();
      });
      await pumpTall(tester);
      await tester.tap(find.text('Pinned leaf'));
      await pumpAsync(tester);

      await tester.tap(find.byIcon(Icons.playlist_add));
      await settle(tester);
      expect(find.text('This task is pinned'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await settle(tester);
      expect(find.byType(TaskPickerDialog), findsNothing);

      await tester.tap(find.byIcon(Icons.playlist_add));
      await settle(tester);
      await tester.tap(find.text('Add anyway'));
      await settle(tester);
      await pickInPicker(tester, 'Other');

      final children =
          await tester.runAsync(() => db.getChildren(leafId)) ?? [];
      expect(children.map((t) => t.name), ['Other']);
      expect(find.text('Other'), findsOneWidget,
          reason: 'the open task now lists its new child');
    });

    testWidgets('a breadcrumb tap jumps back to that level', (tester) async {
      await tester.runAsync(() async {
        final a = await db.insertTask(Task(name: 'Level A'));
        final b = await db.insertTask(Task(name: 'Level B'));
        final c = await db.insertTask(Task(name: 'Level C'));
        await db.addRelationship(a, b);
        await db.addRelationship(b, c);
        await provider.loadRootTasks();
      });
      await pumpTall(tester);
      await tester.tap(find.text('Level A'));
      await pumpAsync(tester);
      await tester.tap(find.text('Level B').last);
      await pumpAsync(tester);
      expect(provider.currentParent?.name, 'Level B');

      await tester.tap(find.text('Level A'));
      await settle(tester);

      expect(provider.currentParent?.name, 'Level A');
      expect(find.text('Level B'), findsOneWidget);
    });
  });

  group('Schedule and link', () {
    testWidgets('card menu Schedule saves the picked weekday', (tester) async {
      late int id;
      await tester.runAsync(() async {
        id = await db.insertTask(Task(name: 'Gym'));
        await provider.loadRootTasks();
      });
      await pumpTall(tester);

      await cardAction(tester, 'Gym', 'Schedule');
      expect(find.text('Repeat weekly'), findsOneWidget);
      await tester.tap(find.text('Mon'));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await settle(tester);

      final schedules = await tester.runAsync(() => provider.getSchedules(id));
      expect(schedules!.map((s) => s.dayOfWeek), [1]);
    });

    testWidgets('overflow Schedule on a leaf saves the picked weekday',
        (tester) async {
      late int id;
      await tester.runAsync(() async {
        id = await db.insertTask(Task(name: 'Gym'));
        await provider.loadRootTasks();
      });
      await pumpTall(tester);
      await tester.tap(find.text('Gym'));
      await pumpAsync(tester);

      await overflowAction(tester, 'Schedule');
      await tester.tap(find.text('Fri'));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await settle(tester);

      final schedules = await tester.runAsync(() => provider.getSchedules(id));
      expect(schedules!.map((s) => s.dayOfWeek), [5]);
    });

    // [Bug] LeafTaskDetail.showEditUrlDialog (leaf_task_detail.dart:122)
    // disposes its TextEditingController in `.then` on showDialog's future,
    // which completes when the route pops, while the dialog's exit transition
    // is still building the TextField. Flutter reports "A
    // TextEditingController was used after being disposed" and the framework
    // assertions that follow break every later test in this file, so this
    // test and the leaf-detail link test stay skipped until the bug is fixed.
    testWidgets('overflow "Add link" saves the URL and shows the link button',
        skip: true, // Bug: the Link dialog's controller is disposed while the
        // dialog is still closing. See the comment above.
        (tester) async {
      late int parentId;
      await tester.runAsync(() async {
        parentId = await db.insertTask(Task(name: 'Project'));
        final childId = await db.insertTask(Task(name: 'Step'));
        await db.addRelationship(parentId, childId);
        await provider.loadRootTasks();
      });
      await pumpTall(tester);
      await tester.tap(find.text('Project'));
      await pumpAsync(tester);
      expect(find.byIcon(Icons.link), findsNothing);

      await overflowAction(tester, 'Add link');
      await tester.enterText(
          find.descendant(
              of: find.byType(AlertDialog), matching: find.byType(TextField)),
          'example.com');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await settle(tester);

      final task = await tester.runAsync(() => db.getTaskById(parentId));
      expect(task!.url, 'https://example.com');
      expect(find.byIcon(Icons.link), findsOneWidget);
    });
  });

  group('Leaf detail actions', () {
    /// Root "Parent" with children "Leaf Task" and "Sibling"; opens the leaf.
    Future<int> openLeaf(WidgetTester tester, {Task? leaf}) async {
      late int leafId;
      await tester.runAsync(() async {
        final parentId = await db.insertTask(Task(name: 'Parent'));
        leafId = await db.insertTask(leaf ?? Task(name: 'Leaf Task'));
        final siblingId = await db.insertTask(Task(name: 'Sibling'));
        await db.addRelationship(parentId, leafId);
        await db.addRelationship(parentId, siblingId);
        await provider.loadRootTasks();
      });
      await pumpTall(tester);
      await tester.tap(find.text('Parent'));
      await pumpAsync(tester);
      await tester.tap(find.text('Leaf Task'));
      await pumpAsync(tester);
      return leafId;
    }

    testWidgets('Start marks the leaf started, and tapping again stops it',
        (tester) async {
      final id = await openLeaf(tester);

      await tester.tap(find.text('Start'));
      await settle(tester);

      var task = await tester.runAsync(() => db.getTaskById(id));
      expect(task!.isStarted, isTrue);
      expect(find.textContaining('Started'), findsOneWidget);

      await tester.tap(find.textContaining('Started'));
      await settle(tester);

      task = await tester.runAsync(() => db.getTaskById(id));
      expect(task!.isStarted, isFalse);
      expect(find.text('Start'), findsOneWidget);
    });

    testWidgets('Skip skips the leaf and goes back; Undo brings it back',
        (tester) async {
      final id = await openLeaf(tester);

      await tester.tap(find.text('Skip'));
      await settle(tester);

      var task = await tester.runAsync(() => db.getTaskById(id));
      expect(task!.isSkipped, isTrue);
      expect(provider.currentParent?.name, 'Parent');
      expect(find.text('Leaf Task'), findsNothing);
      expect(find.text('Sibling'), findsOneWidget);
      expect(find.text('Skipped "Leaf Task"'), findsOneWidget);

      await tapUndo(tester);

      task = await tester.runAsync(() => db.getTaskById(id));
      expect(task!.isSkipped, isFalse);
      expect(find.text('Leaf Task'), findsOneWidget);
    });

    testWidgets('the flag button toggles high priority', (tester) async {
      final id = await openLeaf(tester);

      await tester.tap(find.byTooltip('Set high priority'));
      await settle(tester);

      var task = await tester.runAsync(() => db.getTaskById(id));
      expect(task!.isHighPriority, isTrue);
      expect(find.byTooltip('High priority'), findsOneWidget);

      await tester.tap(find.byTooltip('High priority'));
      await settle(tester);

      task = await tester.runAsync(() => db.getTaskById(id));
      expect(task!.isHighPriority, isFalse);
      expect(find.byTooltip('Set high priority'), findsOneWidget);
    });

    testWidgets('the moon button toggles Someday', (tester) async {
      final id = await openLeaf(tester);

      await tester.tap(find.byTooltip('Mark as someday'));
      await settle(tester);

      final task = await tester.runAsync(() => db.getTaskById(id));
      expect(task!.isSomeday, isTrue);
      expect(find.byTooltip('Someday'), findsOneWidget);
    });

    testWidgets('the link button saves a URL on the leaf',
        skip: true, // Bug: the Link dialog's controller is disposed while the
        // dialog is still closing (see the "Add link" test above).
        (tester) async {
      final id = await openLeaf(tester);

      await tester.tap(find.byTooltip('Add link'));
      await settle(tester);
      await tester.enterText(
          find.descendant(
              of: find.byType(AlertDialog), matching: find.byType(TextField)),
          'https://example.org/page');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await settle(tester);

      final task = await tester.runAsync(() => db.getTaskById(id));
      expect(task!.url, 'https://example.org/page');
      expect(find.byTooltip('Add link'), findsNothing);
    });

    testWidgets('Pin adds the leaf to Today\'s 5 and the button turns to Unpin',
        (tester) async {
      final id = await openLeaf(tester);

      await tester.runAsync(() async {
        await tester.tap(find.byTooltip('Pin'));
      });
      await settle(tester);

      final saved =
          await tester.runAsync(() => db.loadTodaysFiveState(todayDateKey()));
      expect(saved!.taskIds, contains(id));
      expect(saved.pinnedIds, contains(id));
      expect(find.byTooltip('Unpin'), findsOneWidget);
    });

    testWidgets('card menu "Stop working" clears the started state',
        (tester) async {
      late int id;
      await tester.runAsync(() async {
        id = await db.insertTask(Task(name: 'Busy'));
        await db.startTask(id);
        await provider.loadRootTasks();
      });
      await pumpTall(tester);

      await cardAction(tester, 'Busy', 'Stop working');

      final task = await tester.runAsync(() => db.getTaskById(id));
      expect(task!.isStarted, isFalse);
      expect(cardFor(tester, 'Busy').task.isStarted, isFalse);
    });
  });
}

/// A [TaskProvider] whose search-pool read can be held open until [gate]
/// completes, or made to throw [error].
class _SearchLoadProvider extends TaskProvider {
  Completer<void>? gate;
  Object? error;

  @override
  Future<(List<Task>, Map<int, List<String>>)>
      getAllTasksWithParentNames() async {
    if (gate != null) await gate!.future;
    if (error != null) throw error!;
    return super.getAllTasksWithParentNames();
  }
}
