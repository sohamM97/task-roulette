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
}
