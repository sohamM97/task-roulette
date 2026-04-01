import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:task_roulette/data/database_helper.dart';
import 'package:task_roulette/data/xp_config.dart';
import 'package:task_roulette/models/task.dart';
import 'package:task_roulette/providers/progression_provider.dart';

void main() {
  late DatabaseHelper db;
  late ProgressionProvider provider;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    DatabaseHelper.testDatabasePath = inMemoryDatabasePath;
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({'progression_backfill_done': true});
    db = DatabaseHelper();
    await db.reset();
    await db.database;
    provider = ProgressionProvider();
    await provider.init();
  });

  tearDown(() async {
    await db.reset();
  });

  /// Helper to create a real task and return its ID.
  Future<int> createTask([String name = 'Test task']) async {
    return db.insertTask(Task(name: name));
  }

  group('init', () {
    // Baseline: fresh init has 0 XP
    test('starts with 0 XP and default rank', () {
      expect(provider.totalXp, 0);
      expect(provider.tierIndex, 0);
      expect(provider.currentStreak, 0);
      expect(provider.bestStreak, 0);
    });

    // Mechanism: class defaults to adventurer when not chosen
    test('defaults to adventurer class when not chosen', () {
      expect(provider.rankClass, RankClass.adventurer);
      expect(provider.classChosen, isFalse);
    });

    // Mechanism: restores class choice from SharedPreferences
    test('restores class choice from SharedPreferences', () async {
      SharedPreferences.setMockInitialValues({
        'progression_backfill_done': true,
        'progression_rank_class': RankClass.warrior.index,
      });
      final p2 = ProgressionProvider();
      await p2.init();
      expect(p2.rankClass, RankClass.warrior);
      expect(p2.classChosen, isTrue);
    });
  });

  group('awardXp', () {
    // Baseline: awarding XP increases total
    test('increases total XP', () async {
      final taskId = await createTask();
      await provider.awardXp(XpEventType.taskComplete, 20, taskId: taskId);
      expect(provider.totalXp, 20);
    });

    // Mechanism: multiple awards accumulate
    test('multiple awards accumulate', () async {
      final t1 = await createTask('Task 1');
      final t2 = await createTask('Task 2');
      await provider.awardXp(XpEventType.taskComplete, 20, taskId: t1);
      await provider.awardXp(XpEventType.workedOn, 10, taskId: t2);
      expect(provider.totalXp, 30);
    });

    // Mechanism: rank updates when XP crosses threshold
    test('rank updates when crossing threshold', () async {
      // Award enough XP to reach tier 1 (100 XP) using null taskId (special events)
      for (var i = 0; i < 5; i++) {
        await provider.awardXp(XpEventType.todaysFiveComplete, 20);
      }
      expect(provider.totalXp, 100);
      expect(provider.tierIndex, 1);
    });

    // Mechanism: awarding XP with null taskId works (special events)
    test('works with null taskId for special events', () async {
      await provider.awardXp(XpEventType.todaysFiveComplete, 30);
      expect(provider.totalXp, 30);
    });
  });

  group('awardXpWithBonuses', () {
    // Baseline: base XP only (no bonuses)
    test('awards only base XP when no bonuses apply', () async {
      final taskId = await createTask();
      await provider.awardXpWithBonuses(
        eventType: XpEventType.taskComplete,
        baseXp: XpAmounts.taskComplete,
        taskId: taskId,
        isInTodaysFive: false,
        isHighPriority: false,
        isPinned: false,
      );
      expect(provider.totalXp, XpAmounts.taskComplete);
    });

    // Mechanism: Today's 5 bonus added
    test('awards Today\'s 5 bonus when applicable', () async {
      final taskId = await createTask();
      await provider.awardXpWithBonuses(
        eventType: XpEventType.taskComplete,
        baseXp: XpAmounts.taskComplete,
        taskId: taskId,
        isInTodaysFive: true,
        isHighPriority: false,
        isPinned: false,
      );
      expect(provider.totalXp, XpAmounts.taskComplete + XpAmounts.todaysFiveBonus);
    });

    // Mechanism: all bonuses stack
    test('all bonuses stack additively', () async {
      final taskId = await createTask();
      await provider.awardXpWithBonuses(
        eventType: XpEventType.taskComplete,
        baseXp: XpAmounts.taskComplete,
        taskId: taskId,
        isInTodaysFive: true,
        isHighPriority: true,
        isPinned: true,
      );
      final expected = XpAmounts.taskComplete +
          XpAmounts.todaysFiveBonus +
          XpAmounts.highPriorityBonus +
          XpAmounts.pinnedBonus;
      expect(provider.totalXp, expected);
    });

    // Mechanism: high priority bonus only
    test('awards only high priority bonus when applicable', () async {
      final taskId = await createTask();
      await provider.awardXpWithBonuses(
        eventType: XpEventType.taskStarted,
        baseXp: XpAmounts.taskStarted,
        taskId: taskId,
        isInTodaysFive: false,
        isHighPriority: true,
        isPinned: false,
      );
      expect(provider.totalXp, XpAmounts.taskStarted + XpAmounts.highPriorityBonus);
    });
  });

  group('revokeXp', () {
    // Mechanism: revokes base XP and all bonuses for task on today
    test('revokes base XP and bonuses', () async {
      final taskId = await createTask();
      await provider.awardXpWithBonuses(
        eventType: XpEventType.taskComplete,
        baseXp: XpAmounts.taskComplete,
        taskId: taskId,
        isInTodaysFive: true,
        isHighPriority: true,
        isPinned: true,
      );
      final before = provider.totalXp;
      expect(before, greaterThan(0));

      await provider.revokeXp(XpEventType.taskComplete, taskId);
      expect(provider.totalXp, 0);
    });

    // Edge case: revoking when no events exist does nothing
    test('does nothing when no matching events', () async {
      await provider.revokeXp(XpEventType.taskComplete, 999);
      expect(provider.totalXp, 0);
    });

    // Mechanism: only revokes today's events, not other dates
    test('only revokes events from today', () async {
      final taskId = await createTask();
      // Insert event for a past date directly in DB
      await db.insertXpEvent(
        eventType: XpEventType.taskComplete,
        xpAmount: 20,
        taskId: taskId,
        date: '2025-01-01',
      );
      // Award today's event via provider
      await provider.awardXp(XpEventType.taskComplete, 20, taskId: taskId);
      expect(provider.totalXp, 40);

      // Revoke only removes today's
      await provider.revokeXp(XpEventType.taskComplete, taskId);
      expect(provider.totalXp, 20); // past event survives
    });
  });

  group('setRankClass', () {
    // Baseline: changes class and updates rank title
    test('changes class and persists', () async {
      await provider.setRankClass(RankClass.mage);
      expect(provider.rankClass, RankClass.mage);
      expect(provider.classChosen, isTrue);
      expect(provider.rankTitle, 'Initiate'); // Mage tier 0
    });

    // Mechanism: class change updates rank title without changing XP
    test('class change updates title but not XP', () async {
      final taskId = await createTask();
      await provider.awardXp(XpEventType.taskComplete, 20, taskId: taskId);
      final xpBefore = provider.totalXp;
      await provider.setRankClass(RankClass.warrior);
      expect(provider.totalXp, xpBefore);
      expect(provider.rankTitle, 'Apprentice'); // Warrior tier 0
    });
  });

  group('rankProgress', () {
    // Baseline: 0 XP = 0 progress
    test('returns 0 at start', () {
      expect(provider.rankProgress, 0.0);
    });

    // Mechanism: mid-tier progress
    test('returns fractional progress mid-tier', () async {
      // Use null taskId (special event) to avoid FK constraint
      await provider.awardXp(XpEventType.todaysFiveComplete, 50);
      // Tier 0 is 0–99 (range 100), so 50 XP = 0.5
      expect(provider.rankProgress, closeTo(0.5, 0.01));
    });
  });

  group('weekly stats', () {
    // Baseline: fresh provider has zero weekly data
    test('starts with zero weekly data', () {
      expect(provider.weeklyXp, List.filled(7, 0));
      expect(provider.weeklyCompletions, List.filled(7, 0));
      expect(provider.weekActiveDays, 0);
    });
  });
}
