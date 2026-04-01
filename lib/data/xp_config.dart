/// XP amounts, bonus multipliers, and rank definitions for the progression system.
///
/// All XP values and rank thresholds are defined here so they can be tuned
/// without touching business logic. Ranks use an exponential curve (~2x per tier).
library;

/// XP earned per action type.
class XpAmounts {
  XpAmounts._();

  // Base actions
  static const workedOn = 10; // "Done today"
  static const taskComplete = 20; // "Done for good"
  static const taskStarted = 5; // Marked in-progress

  // Bonus multipliers (additive, stackable)
  static const todaysFiveBonus = 5; // Action on a Today's 5 task
  static const highPriorityBonus = 5; // Action on a priority=1 task
  static const pinnedBonus = 5; // Action on a pinned Today's 5 task

  // Special events
  static const allTodaysFiveComplete = 30; // All Today's 5 done
  static const streakBonus = 5; // Per consecutive active day
  static const maxStreakBonusDays = 30; // Cap streak bonus accumulation
}

/// Event type constants stored in the xp_events table.
class XpEventType {
  XpEventType._();

  static const workedOn = 'worked_on';
  static const taskComplete = 'task_complete';
  static const taskStarted = 'task_started';
  static const todaysFiveComplete = 'todays_five_complete';
  static const streakBonus = 'streak_bonus';

  // Bonus events (separate rows so they can be individually revoked)
  static const todaysFiveBonus = 'todays_five_bonus';
  static const highPriorityBonus = 'high_priority_bonus';
  static const pinnedBonus = 'pinned_bonus';
}

/// The three class paths a user can choose from.
enum RankClass {
  warrior,
  adventurer,
  mage,
}

/// A single rank tier with per-class titles.
class RankTier {
  const RankTier({
    required this.minXp,
    required this.warrior,
    required this.adventurer,
    required this.mage,
  });

  final int minXp;
  final String warrior;
  final String adventurer;
  final String mage;

  String titleFor(RankClass rankClass) {
    switch (rankClass) {
      case RankClass.warrior:
        return warrior;
      case RankClass.adventurer:
        return adventurer;
      case RankClass.mage:
        return mage;
    }
  }
}

/// Rank definitions. Exponential curve: each tier ~2x the previous.
class RankConfig {
  RankConfig._();

  static const tiers = [
    RankTier(minXp: 0, warrior: 'Apprentice', adventurer: 'Novice', mage: 'Initiate'),
    RankTier(minXp: 100, warrior: 'Squire', adventurer: 'Adventurer', mage: 'Acolyte'),
    RankTier(minXp: 300, warrior: 'Knight', adventurer: 'Pathfinder', mage: 'Scribe'),
    RankTier(minXp: 700, warrior: 'Vanguard', adventurer: 'Sentinel', mage: 'Enchanter'),
    RankTier(minXp: 1500, warrior: 'Champion', adventurer: 'Champion', mage: 'Sorcerer'),
    RankTier(minXp: 3000, warrior: 'Warlord', adventurer: 'Vanquisher', mage: 'Archmage'),
    RankTier(minXp: 6000, warrior: 'Conqueror', adventurer: 'Paragon', mage: 'Sage'),
    RankTier(minXp: 12000, warrior: 'Mythic', adventurer: 'Mythic', mage: 'Mythic'),
  ];

  /// Returns the current rank info for [totalXp] and [rankClass].
  ///
  /// Returns a record with:
  /// - [title]: the rank title string
  /// - [tierIndex]: index into [tiers] (0-based)
  /// - [currentMin]: XP threshold for this rank
  /// - [nextMin]: XP threshold for next rank, or null if max rank
  static ({String title, int tierIndex, int currentMin, int? nextMin}) rankFor(
    int totalXp,
    RankClass rankClass,
  ) {
    var tierIndex = 0;
    for (var i = tiers.length - 1; i >= 0; i--) {
      if (totalXp >= tiers[i].minXp) {
        tierIndex = i;
        break;
      }
    }
    final tier = tiers[tierIndex];
    final nextMin = tierIndex < tiers.length - 1 ? tiers[tierIndex + 1].minXp : null;
    return (
      title: tier.titleFor(rankClass),
      tierIndex: tierIndex,
      currentMin: tier.minXp,
      nextMin: nextMin,
    );
  }

  /// Progress fraction (0.0–1.0) within the current rank tier.
  /// Returns 1.0 if at max rank.
  static double progressFraction(int totalXp, int currentMin, int? nextMin) {
    if (nextMin == null) return 1.0;
    final range = nextMin - currentMin;
    if (range <= 0) return 1.0;
    return ((totalXp - currentMin) / range).clamp(0.0, 1.0);
  }
}
