import 'package:flutter_test/flutter_test.dart';
import 'package:task_roulette/data/xp_config.dart';

void main() {
  group('RankConfig.rankFor', () {
    // Baseline: returns correct rank for 0 XP
    test('returns first tier for 0 XP', () {
      final rank = RankConfig.rankFor(0, RankClass.adventurer);
      expect(rank.title, 'Novice');
      expect(rank.tierIndex, 0);
      expect(rank.currentMin, 0);
      expect(rank.nextMin, 100);
    });

    // Baseline: returns correct rank for each class at tier 0
    test('returns correct class-specific title at tier 0', () {
      expect(RankConfig.rankFor(0, RankClass.warrior).title, 'Apprentice');
      expect(RankConfig.rankFor(0, RankClass.adventurer).title, 'Novice');
      expect(RankConfig.rankFor(0, RankClass.mage).title, 'Initiate');
    });

    // Mechanism: exact boundary transitions
    test('transitions to next tier at exact threshold', () {
      final rank99 = RankConfig.rankFor(99, RankClass.adventurer);
      expect(rank99.tierIndex, 0);

      final rank100 = RankConfig.rankFor(100, RankClass.adventurer);
      expect(rank100.tierIndex, 1);
      expect(rank100.title, 'Adventurer');
      expect(rank100.currentMin, 100);
      expect(rank100.nextMin, 300);
    });

    // Mechanism: mid-tier XP returns correct tier
    test('mid-tier XP returns correct tier', () {
      final rank = RankConfig.rankFor(500, RankClass.warrior);
      expect(rank.tierIndex, 2); // 300–699 = Knight
      expect(rank.title, 'Knight');
    });

    // Mechanism: max rank has null nextMin
    test('max rank has null nextMin', () {
      final rank = RankConfig.rankFor(12000, RankClass.mage);
      expect(rank.tierIndex, 7);
      expect(rank.title, 'Mythic');
      expect(rank.nextMin, isNull);
    });

    // Edge case: very high XP stays at max rank
    test('very high XP stays at max rank', () {
      final rank = RankConfig.rankFor(999999, RankClass.adventurer);
      expect(rank.tierIndex, 7);
      expect(rank.title, 'Mythic');
      expect(rank.nextMin, isNull);
    });

    // Mechanism: all tiers have correct class titles
    test('tier 3 returns correct class-specific titles', () {
      expect(RankConfig.rankFor(700, RankClass.warrior).title, 'Vanguard');
      expect(RankConfig.rankFor(700, RankClass.adventurer).title, 'Sentinel');
      expect(RankConfig.rankFor(700, RankClass.mage).title, 'Enchanter');
    });
  });

  group('RankConfig.progressFraction', () {
    // Baseline: 0 XP at tier 0 = 0% progress
    test('returns 0.0 at start of tier', () {
      expect(RankConfig.progressFraction(0, 0, 100), 0.0);
    });

    // Mechanism: mid-tier progress
    test('returns 0.5 at midpoint', () {
      expect(RankConfig.progressFraction(50, 0, 100), 0.5);
    });

    // Mechanism: just before next tier
    test('returns close to 1.0 just before next tier', () {
      expect(RankConfig.progressFraction(99, 0, 100), closeTo(0.99, 0.01));
    });

    // Mechanism: max rank returns 1.0
    test('returns 1.0 when nextMin is null (max rank)', () {
      expect(RankConfig.progressFraction(12000, 12000, null), 1.0);
    });

    // Edge case: XP exactly at nextMin returns 1.0 (clamped)
    test('returns 1.0 when at exact nextMin boundary', () {
      expect(RankConfig.progressFraction(100, 0, 100), 1.0);
    });
  });

  group('RankTier.titleFor', () {
    // Baseline: returns correct title for each class
    test('returns class-specific title', () {
      const tier = RankTier(
        minXp: 0,
        warrior: 'W',
        adventurer: 'A',
        mage: 'M',
      );
      expect(tier.titleFor(RankClass.warrior), 'W');
      expect(tier.titleFor(RankClass.adventurer), 'A');
      expect(tier.titleFor(RankClass.mage), 'M');
    });
  });

  group('XpAmounts constants', () {
    // Baseline: verify key XP values exist and are positive
    test('all XP amounts are positive', () {
      expect(XpAmounts.workedOn, greaterThan(0));
      expect(XpAmounts.taskComplete, greaterThan(0));
      expect(XpAmounts.taskStarted, greaterThan(0));
      expect(XpAmounts.todaysFiveBonus, greaterThan(0));
      expect(XpAmounts.highPriorityBonus, greaterThan(0));
      expect(XpAmounts.pinnedBonus, greaterThan(0));
      expect(XpAmounts.allTodaysFiveComplete, greaterThan(0));
      expect(XpAmounts.streakBonus, greaterThan(0));
    });

    // Mechanism: task_complete > worked_on > task_started (reward hierarchy)
    test('XP values follow expected hierarchy', () {
      expect(XpAmounts.taskComplete, greaterThan(XpAmounts.workedOn));
      expect(XpAmounts.workedOn, greaterThan(XpAmounts.taskStarted));
    });
  });
}
